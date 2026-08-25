# Mage-VL 独自 MLX 移植 Stage 3: proactive streaming gate parity

Mage-VL の MLX 移植シリーズの検証です。
[検証方針](../../../../docs/mage-vl-mlx-port.md)の Stage 3 として、
映像から自発的な発話タイミングを判定する proactive streaming gate を MLX で実装し、
一致を検証しました(2026-08-25)。
前段は [Stage 2: torch-free video parity](../mage-vl-mlx-stage2-video-parity/README.md) です。

Apple Silicon 上で streaming gate の参照実装との一致を定量的に確認した報告は、
2026-08-25 時点で確認できていません。

## 目的と問い

- streaming Mamba mixer と speak / silent 判定を MLX で実装し、一致させられるか
- Stage 3 の gate を満たすか
  - Mamba mixer の最大絶対誤差 `1.0e-5` 以下
  - 参照動画に対する speak / silent timeline が fixture と一致
- 着手前の懸案だった「`mamba-ssm` を要求する gate の fixture を macOS で生成できるか」に
  どう対処するか

## gate の構造

公式 `streammind_gate.py` を読んで把握した構成です。

1. **EPFE token 化**: 各 frame の visual patch を平均プールし、frame ごとに 1 token にする
2. **PreNet**: Linear + leaky ReLU
3. **VideoMamba**: Mamba1 ブロック 1 個(LayerNorm + selective scan mixer)+ LayerNorm
4. **PostNet**: leaky ReLU + Linear
5. **ClsNet**: 4 層 Qwen3(vocab 2)。各時刻について
   「EPFE token, target embedding」という長さ 2 の系列を作り、
   位置 0 の logits を silent / speak の 2 値として読む

重みの形状から Mamba1 の既定値(d_model 2560、expand 2、d_state 16、d_conv 4、
dt_rank 160、in/out/x_proj は bias なし、block norm は RMSNorm ではなく LayerNorm)と
確認できました。ClsNet の rope_theta は Qwen3Config の既定値 **10000** で、
本体 decoder の 5e6 とは異なります。

## fixture 生成手段の決定(着手前の懸案)

`mamba-ssm` は macOS に install できません。setup.py が `torch.version.cuda` を
parse しますが、macOS では None のため `InvalidVersion` で失敗します
(`MAMBA_SKIP_CUDA_BUILD=TRUE` でも同じ)。

そこで、SSM ブロックだけを pure PyTorch で再実装し
(`scripts/reference_gate.py`、mamba_ssm 公開の `selective_scan_ref` と
`mamba_simple.Mamba.forward` の非 fast path の意味論に従う)、これを参照としました。
gate の他の部分(PreNet、PostNet、LayerNorm、4 層 Qwen3)は
stock の PyTorch / transformers を使うため公式コード経路そのものです。

この再実装は公式 checkpoint の 64 key を **missing 0 / unexpected 0** で読み込めており、
構造が一致していることは確認できます。ただし
**mamba-ssm の CUDA kernel との一致は未検証**です。この点は検証方針の
「手段が確保できない場合は gate を再定義して記録する」に従い、制約として明示します。

## 実行方法

移植本体は [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)
commit `1070188` です。

```sh
git clone https://github.com/kiarina/mage-vl-mlx
cd mage-vl-mlx && git checkout 1070188
uv sync --group fixtures
.venv/bin/python scripts/install_mamba_stub.py
.venv/bin/python scripts/convert_weights.py
.venv/bin/python scripts/convert_gate_weights.py
scripts/make_testdata.sh /path/to/labs/tests/assets/jpg

.venv/bin/python scripts/generate_gate_fixtures.py \
  --video testdata/pan_objects.mp4 --video testdata/street_ocr.mp4 \
  --video testdata/faces_odd.mp4 --video testdata/cut_event.mp4
.venv/bin/python scripts/check_gate_parity.py
```

## 検証条件

Stage 2 の 3 本に加え、gate を発火させるための `cut_event`(黒画面 1.5 秒 →
`many_face` へのハードカット 1.5 秒、768x512、30 fps)を使用します。
いずれも共有アセットから ffmpeg で決定的に生成します。

- 参照: `microsoft/Mage-VL` revision `d88b153`、float32、CPU。
  vision token は公式の `_streammind_vision_tokens` で生成
- 環境: Apple M4 Max、128 GB、macOS 26.5.2、torch 2.13.0、
  transformers 5.15.1、mlx 0.32.1

## 観測した事実

### 重み

gate の 64 key すべてを写像でき、missing 0 / unused 0 / shape 不一致 0。

### Mamba mixer の一致(gate 1)

mixer に**参照側と同一の入力**を与えて比較しました。

| クリップ | mixer 最大絶対誤差 | 相対誤差 |
|---|---:|---:|
| pan_objects | 2.682e-07 | 1.213e-06 |
| street_ocr | 3.055e-07 | 1.194e-06 |
| faces_odd | 3.874e-07 | 1.120e-06 |
| cut_event | 4.396e-07 | 1.139e-06 |

gate の `1.0e-5` を大きく下回ります。

なお、動画から end-to-end で通した場合の VideoMamba 出力の最大絶対誤差は
`1.19e-05`〜`1.43e-05` で、`1.0e-5` をわずかに超えます。切り分けたところ、
差は mixer ではなく上流(平均プールと PreNet の Linear)で生じ、
LayerNorm と residual を通って増幅していました。同一入力での PreNet 出力の
最大絶対誤差は 3.219e-06、block norm は 9.537e-07 です。
gate は mixer に対する条件であるため、単独計測の値で判定しました。

### speak / silent timeline の一致(gate 2)

4 本すべてで timeline が一致しました。`p_speak` の最大絶対差は
5.19e-08〜2.66e-06 です。

| クリップ | 参照 `p_speak`(float32) |
|---|---|
| pan_objects | 0.0013, 0.0035, 0.0014, 0.0077, 0.0137, 0.0049, 0.0138, 0.0022 |
| street_ocr | 0.0000, 0.0001, 0.0001, 0.0012, 0.0066, 0.0031, 0.0151, 0.0025 |
| faces_odd | 0.0000, 0.0001, 0.0002, 0.0046, 0.0030, 0.0021, 0.0011, 0.0039 |
| cut_event | **0.5022, 0.7206, 0.5006, 0.8958**, 0.0009, 0.0004, 0.0006, 0.0001 |

合成クリップ 3 本では gate は終始 silent でした。全時刻が silent の timeline は
検証として弱いため、発火するクリップを探したところ、黒画面からのハードカットで
speak 側に振れることが分かりました。`cut_event` は speak 4 / silent 4 の混在に加え、
閾値 0.5 のすぐ上(0.5006、0.5022)という数値誤差に最も敏感な値を含みます。

発火したのは**黒画面の区間**(frame 0, 13, 25, 38)で、内容が現れた後は
silent でした。gate は sports broadcast で学習されているため、
この挙動が意図された動作かは判断できません。

### bfloat16 では判定が反転する

移植を bfloat16 で end-to-end 実行すると、`cut_event` の timeline が
float32 参照と一致しませんでした。

| 時刻 | float32 | bfloat16 | 判定 |
|---|---:|---:|---|
| 0 | 0.5022 | 0.4977 | **speak → silent に反転** |
| 1 | 0.7206 | 0.7420 | 一致 |
| 2 | 0.5006 | 0.5297 | 一致 |
| 3 | 0.8958 | 0.8977 | 一致 |

`pan_objects` のように全値が閾値から離れているクリップでは bfloat16 でも一致します。

### 性能

bfloat16、8 frame のクリップ 1 本について、前処理から gate の logits までで
0.77〜0.99 秒(M4 Max)。

## 解釈と評価

- **Stage 3 は float32 で通過**と判断する。ただし参照の SSM が
  公式 CUDA kernel ではなく本移植の pure PyTorch 再実装である点は制約として残る
- mixer の誤差 2.7e-07〜4.4e-07 は、gate 基準の 1/20 以下であり、
  selective scan の実装が正しいことを支持する
- gate の数値条件を end-to-end で測ると上流の誤差を含んでしまい、
  「mixer の誤差」という条件の意味が変わる。条件が特定の module を指す場合、
  その module に同一入力を与えて測る必要がある
- **streaming gate の判定は bfloat16 に対して頑健でない。**
  `p_speak` が 0.5 付近にあるとき、bfloat16 の丸めだけで speak / silent が反転する。
  実用上、判定の再現性が要る場面では float32 で動かす必要がある。
  これは Stage 1・2 の「bfloat16 では greedy 一致が保証されない」と同根だが、
  2 値判定という出力形式のため影響がより直接的である
- 合成クリップでは gate がほとんど発火しない。学習分布(sports broadcast)と
  離れているためと推測するが、確認していない

## 未確認事項と制約

- **mamba-ssm の CUDA kernel との一致は未検証。** 本 lab が示すのは
  「公開されている参照アルゴリズムに対する一致」であり、
  公式が実際に実行する kernel との一致ではない
- 検証は 8 frame・4 本のみ。長い系列、`streammind_gate_forward_segments` による
  segment をまたぐ連続 EPFE、`response_positions` を与える経路は未検証
- gate が発火した唯一のクリップは黒画面からのハードカットであり、
  実写の「イベント」ではない。実映像での挙動と遅延は測定していない
- 検証方針が挙げる「event 発生から speak 判定までの遅延」は未測定。
  合成クリップでは event 時刻を定義できないため
- 閾値は 0.5 を仮定した。公式が推奨する τ は確認していない
- codec 経路(Stage 4)は未実装。公式は streaming に codec backend を推奨しており、
  frame 入力での検証は公式の推奨構成とは異なる

## 参照

シリーズの前の研究:

- [Stage 2: torch-free frame-sampled video parity](../mage-vl-mlx-stage2-video-parity/README.md)(2026-08-25)
- [Stage 1: 静止画 parity](../mage-vl-mlx-stage1-image-parity/README.md)(2026-08-25)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)
- [MLX 移植の parity 検証](../../../../docs/mlx-port-parity.md)

外部:

- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)(移植リポジトリ)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
- [state-spaces/mamba](https://github.com/state-spaces/mamba)
