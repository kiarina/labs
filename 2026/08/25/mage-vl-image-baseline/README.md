# Mage-VL 静止画推論の Mac ベースライン(公式 PyTorch と mlx-vlm)

Mage-VL の MLX 移植シリーズの検証です。
[検証方針](../../../../docs/mage-vl-mlx-port.md)の Stage 1(静止画 parity)の
前提である「fixture 生成元となる公式 PyTorch 実装が Mac で動くか」を確認し、
あわせて標準 mlx-vlm の静止画・動画推論を同一入力で実測しました(2026-08-25)。
前提となる調査は
[Mage-VL on MLX and Apple Silicon](../../05/mage-vl-mlx-mac/README.md)(2026-08-05)と
[Mage-VL と MLX 対応の追跡調査](../../24/mage-vl-mlx-update/README.md)(2026-08-24)を
参照してください。

## 目的と問い

- 公式 PyTorch 実装(`microsoft/Mage` の `inference_base.py`)は、
  CUDA 前提の依存(`codec-video-prep`、`mamba-ssm`、`flash-attn`)なしで
  macOS の静止画推論を完走できるか。これは Stage 1 の fixture 生成環境の成立条件
- 標準 mlx-vlm の静止画推論と動画 frames fallback は、この Mac で動くか。
  第三者 model card の値ではなく、自分の環境の観測値を得る
- 公式 BF16 と mlx 8bit の greedy 出力はどの程度一致するか

## 実行方法

```sh
mise run setup   # venv 作成、microsoft/Mage の pinned clone、依存の install
mise run         # 測定一式(要 HF checkpoint ダウンロード 約 16 GB)
```

生成物とログは `output/` に保存され、Git には追加されません。

## 検証条件

- 入力画像: `tests/assets/jpg/objects_1536x1024_358kb.jpg`(共有アセット)
- prompt: `Describe this image.`、greedy(`do_sample=False` / `temperature 0`)、
  max 64 token、各 3 回測定
- 公式実装: `microsoft/Mage` commit `76bec2b`、
  checkpoint `microsoft/Mage-VL` revision `d88b153`(BF16、約 10.8 GB)
- mlx 側: mlx-vlm 0.6.15、mlx 0.32.1、
  checkpoint `mlx-community/Mage-VL-8bit`(約 5.4 GB)
- 動画: ffmpeg `testsrc2` の合成 H.264 クリップ(4 秒、640x360、30 fps)。
  実行時に決定的に再生成できるため共有アセットには登録しない

## 実行環境

- Apple M4 Max、128 GB unified memory、macOS 26.5.2
- torch 2.13.0、torchvision 0.28.0、transformers 5.15.1、accelerate 1.14.0
- Python 3.12.11(uv venv、torch 用と mlx 用を分離)

## 観測した事実

### 公式 PyTorch 実装は macOS(MPS)で動いた

`device_map="auto"` で model は `mps:0`、dtype は bfloat16 に配置され、
greedy 64 token の生成が完走した。

| 指標 | 観測値 |
|---|---:|
| model load | 2.49 秒 |
| prompt tokens | 1561 |
| decode(3 回) | 16.55 / 16.71 / 16.80 token/s(中央値 16.71) |
| peak RSS | 9.44 GB |

ただし、そのままでは動かず、次の 2 つの対処が必要だった。

1. checkpoint の remote code が静止画でも `cv2` を import する。
   `opencv-python` の追加 install で解決
2. transformers の静的 import 検査(`check_imports`)が `mamba_ssm` を要求して
   ImportError になる。原因は `modeling_mage_vl.py` が streaming gate
   (`streammind_gate.py`、先頭で `from mamba_ssm.models.mixer_seq_simple
   import create_block`)を参照するため。実行時は
   `_load_streammind_gate()` 内の遅延 import であり静止画経路では呼ばれないので、
   空の stub package を venv に置くことで通過した。stub は import 検査対策であり、
   streaming 経路はこの環境では動かない

このほか、transformers 5.15.1 で `cache_position` の deprecation warning が出る。
また revision を固定しないと `streammind_gate.py` の新版が実行時に
再ダウンロードされることを観測したため、測定スクリプトでは revision を固定した。

### mlx-vlm 0.6.15 の静止画推論

`mlx_vlm.generate` はそのままでは `jinja2` の ImportError で失敗した
(mlx-vlm 0.6.15 の依存に含まれない)。追加 install 後は完走した。

| 指標 | 観測値 |
|---|---:|
| prompt tokens | 1561(公式実装と一致) |
| prompt 処理 | 約 945 token/s |
| decode(3 回) | 91.49 / 91.56 / 91.37 token/s(中央値 91.49) |
| MLX peak memory | 6.827 GB |

### 動画 frames fallback

`--video` を与えると、mlx-vlm は
`MageVLProcessor has no native video support; sending 8 of 8 sampled frames
as ordered images.` と明示して、frame を画像列として処理した。
4 秒のクリップから 8 frame が選ばれ(`--video-max-frames 16` 指定でも 8)、
prompt 1799 token、生成 97.3 token/s で完走した。合成パターン入力のため
生成内容の質的評価はできない(出力は "A video of a game of Tetris." だった)。

### 公式 BF16 と mlx 8bit の出力比較

同一画像・同一 prompt の greedy 64 token は、ほぼ同一だが完全一致ではなかった。

- 公式 BF16(MPS): "The window has white frames and offers a view of ..."
- mlx 8bit: "The window has a white frame and offers a view of ..."

差は 64 token 中この 1 句のみで、他は一致した。

### 失敗した試行と測定のやり直し

- 最初の測定は torch と mlx を並行実行したため、GPU を取り合って
  数値が劣化・変動した(mlx 42.8 → 27.0 token/s、torch 9.1 → 15.3 token/s)。
  この測定は破棄し、順次実行で取り直した。上の表は順次実行の値
- 公式実装の初回実行は `cv2`、2 回目は `mamba_ssm` の ImportError で失敗した
  (上記のとおり解決)

## 解釈と評価

- Stage 1 の gate 検証に必要な「公式実装による fixture 生成」は、
  この Mac 単体で成立する。`codec-video-prep` なしで静止画経路が完走することも
  確認でき、検証方針のリスク項目のうち静止画分は解消した
- prompt token 数が公式と mlx で一致(1561)したことは、画像前処理と
  chat template の整合の傍証になる。ただし中間 tensor の一致検証ではない
- 8bit 量子化では greedy 出力が完全一致しないことが実例で確認できた。
  Stage 1 の完全一致 gate を BF16 変換重みで行い、量子化は一致率の記録に
  とどめる計画は妥当
- mlx-vlm の動画対応は実行ログ上も「ordered images」であり、upstream の
  video processor 相当ではない。Stage 2(公式 frame sampler との一致)の
  検証対象は残っている

## 未確認事項と制約

- MPS 上の bfloat16 演算が公式評価環境(CUDA)や CPU と数値一致するかは
  未検証。Stage 1 の fixture を MPS で生成してよいかは、CPU 実行との比較を
  含めて別途判断が必要
- 測定は 1 画像、1 prompt、64 token、3 回のみ。負荷や長文生成での挙動、
  電源・温度条件は統制していない
- mamba_ssm stub のため streaming gate はこの環境では動かない。
  gate を含む経路の検証は Stage 3 の課題のまま
- 動画 fallback の frame 選択規則(なぜ 8 frame か)はコード未精読
- `/usr/bin/time -l` と `resource.getrusage` の peak RSS は
  実行条件が異なり、それぞれ 10.1 GB / 9.44 GB と微差がある

## 参照

シリーズの前の研究:

- [Mage-VL on MLX and Apple Silicon](../../05/mage-vl-mlx-mac/README.md)(2026-08-05)
- [Mage-VL codec-native 前処理の macOS 移植性調査](../../05/mage-vl-codec-prep-portability/README.md)(2026-08-05)
- [Mage-VL と MLX 対応の追跡調査](../../24/mage-vl-mlx-update/README.md)(2026-08-24)
- [codec-video-prep の container 実機検証](../codec-video-prep-container/README.md)(2026-08-25)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)

外部:

- [Microsoft Mage repository](https://github.com/microsoft/Mage/tree/main/mage_vl)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
- [MLX 8-bit checkpoint](https://huggingface.co/mlx-community/Mage-VL-8bit)
- [MLX-VLM](https://github.com/Blaizzy/mlx-vlm)
