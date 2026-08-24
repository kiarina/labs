# codec-video-prep aarch64 wheel の ARM64 Linux container 実機検証

Mage-VL の MLX 移植シリーズの検証です。
[Mage-VL codec-native 前処理の macOS 移植性調査](../../05/mage-vl-codec-prep-portability/README.md)(2026-08-05)が
机上で特定した「ARM64 Linux container で `codec-video-prep` を実行する」経路が
実際に動作するかを、2026-08-25 に実機で確認しました。
[追跡調査](../../24/mage-vl-mlx-update/README.md)(2026-08-24)と
[検証方針](../../../../docs/mage-vl-mlx-port.md)の Stage 4 の前提検証にあたります。

## 目的と問い

- PyPI の `codec_video_prep-0.2.5` aarch64 wheel(manylinux_2_35)は、
  Apple Silicon 上の ARM64 Linux container に install して import・実行できるか
- `cv-preinfer` は GPU なしの container で完走し、codec asset を出力するか
- 出力される asset directory は何で構成されるか(従来未確認だった format)

## 実行方法

```sh
mise run
```

`.mise/tasks/default` が次を行います。ログと生成物は `output/` に保存され、
Git には追加されません。

1. ホスト環境(`sw_vers`、docker version)を記録する
2. `python:3.12-slim-bookworm`(ARM64)container で
   ffmpeg を install し、`codec-video-prep==0.2.5` を pip install する
3. container 内の ffmpeg で合成テスト動画を生成する
   (`testsrc2`、4 秒、640x360、30 fps、libx264、yuv420p、GOP 30)
4. `cv-preinfer --video input.mp4 --out_dir output/preinfer` を
   デフォルト設定で実行し、出力を一覧する

入力動画は ffmpeg の `testsrc2` で container 内で毎回決定的に再生成できるため、
共有アセットとしては登録していません。

## 実行環境

- ホスト: macOS 26.5.2(Apple Silicon、arm64)
- Docker Engine 29.7.2(linux/arm64)
- container: `python:3.12-slim-bookworm`(glibc 2.36、Python 3.12.14)
- ffmpeg 5.1.9-0+deb12u1(Debian package)
- codec-video-prep 0.2.5(`manylinux_2_35_aarch64` wheel)

## 観測した事実

### install と実行は成功した

- pip install は wheel をそのまま解決し、エラーなく完了した
- `cv-preinfer` はデフォルト設定で完走した。処理時間は 4 秒・120 frame の
  入力に対して total 0.346 秒(内訳: cv_reader 0.135 秒、canvas_build 0.025 秒)。
  GPU は存在しない環境であり、traditional engine に CUDA が不要なことが
  実行で確認できた
- 途中で CUDA、GPU、未解決 shared library に関する warning・error は出なかった

### 出力された asset directory の構成

`out_dir` には次が出力された。

- `canvas_000.jpg` 〜 `canvas_015.jpg`: 選択 patch を詰めた canvas 画像
  (処理解像度 280x504)。目視で、入力 frame の断片が敷き詰められていることを確認
- `meta.json`(約 70 key): 実行時の全 config、group 構成、sampled frames、
  timing などを含む
- `frame_ids.npy`: int32、shape `(120,)`
- `src_patch_position.npy`: int32、shape `(11520, 3)`。
  11520 = canvas 16 枚 × 720 patch(280/14 × 504/14)

### meta.json から読めたデフォルト設定

`patch=14`、`block_size=2`、`grouping_mode=readiness`、`images_per_group=4`、
`bitcost_grid=adaptive`、`avoid_keyframes=true`、`max_pixels=153664`、
`frame_sampling_mode=uniform_count`(`num_sampled_frames=1024`)。
今回の入力では 120 frame 全部が sample され、keyframe は 4 個検出、
group は 4 個構成された。

### CLI が公開している algorithm の構造

`cv-preinfer --help` は、bitcost grid(`sub` / `mb` / `ctu` / `adaptive`)、
readiness threshold の算出 mode、pkt_peak による frame sampling、
keyframe 回避など、patch 選択 algorithm の主要な調整点を option として
公開している。ソースは非公開のままだが、机上調査の時点より
algorithm の構造はかなり具体的に観測できる。

### 失敗した試行

- 最初の実行は exit code 141(SIGPIPE)で失敗した。原因は task script 内の
  `set -o pipefail` と `コマンド | head -1` の組み合わせで、検証対象とは無関係。
  `awk "NR==1"` に置き換えて解決した

## 解釈と評価

- [机上調査](../../05/mage-vl-codec-prep-portability/README.md)で「可能性が高い」と
  していた container 経路は、実機で動作が確認できた。
  [検証方針](../../../../docs/mage-vl-mlx-port.md)の Stage 4 で最初の確認事項と
  していた項目は解消された
- 未確認だった codec asset directory の format は、少なくとも構成ファイルと
  配列 shape のレベルで観測できた。macOS 側の実装が消費すべき入力の仕様が
  具体化した
- glibc 2.36 の Debian bookworm で動いたため、wheel の要求
  (manylinux_2_35 = glibc 2.35 以上)どおりの互換性と解釈する

## 未確認事項と制約

- 入力は合成パターン 1 本、H.264 のみ。HEVC / VP9、実写、長尺、
  高解像度は未検証
- 出力の「正しさ」は検証していない。動作確認のみであり、
  公式実行環境(x86-64 Linux)との出力一致は別途 fixture 比較が必要
- ffmpeg のバージョン・build 差が bitcost 抽出結果に影響するかは不明
- `--save_mask_video` などの補助出力、`--decode_backend` の別系統は未実行
- `codec-video-prep` の license は依然未宣言のままであり、
  成果公開時の利用条件の確認が必要

## 参照

シリーズの前の研究:

- [Mage-VL codec-native 前処理の macOS 移植性調査](../../05/mage-vl-codec-prep-portability/README.md)(2026-08-05)
- [Mage-VL と MLX 対応の追跡調査](../../24/mage-vl-mlx-update/README.md)(2026-08-24)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)

外部:

- [codec-video-prep on PyPI](https://pypi.org/project/codec-video-prep/)
- [Microsoft Mage repository](https://github.com/microsoft/Mage/tree/main/mage_vl)
