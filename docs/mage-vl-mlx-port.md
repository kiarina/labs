# Mage-VL 独自 MLX 移植の検証方針

この文書は、mlx-vlm に依存しない Mage-VL の独自 MLX 移植を段階的に進めるための
検証方針を定める。調査の前提と用語は
[`2026/08/05/mage-vl-mlx-mac`](../2026/08/05/mage-vl-mlx-mac/README.md) を参照する。

## 目的と問い

次の点を明らかにする。

- Mage-VL の全機能(静止画、frame-sampled video、proactive streaming、
  codec-native sparse video)を、mlx-vlm に依存しない独立実装として
  MLX で再現できるか
- Mage-VL の主要な特徴である codec-native 経路の visual token 削減と速度向上が、
  Apple Silicon の unified memory 環境でも成立するか
- 動画・streaming 経路について、PyTorch 参照実装との end-to-end 一致を
  定量的に確認できるか。これは 2026-08-05 時点で誰も報告していない

## 構成

- 移植本体は labs とは別のリポジトリで開発する。labs には stage ごとの検証記録を
  独立した lab として残す
- 各 lab は、使用した移植コードの commit hash と checkpoint の revision を
  固定して記録する
- 移植本体のコードを labs へ import しない。lab には実行手順と観測結果だけを置く

## 参照実装と役割

| 参照 | 役割 |
|---|---|
| `microsoft/Mage` (PyTorch 公式) | 全経路の正。parity fixture の生成元 |
| `Blaizzy/mlx-vlm` PR 1745 | 静止画の検証済み MLX 実装。二次参照 |
| `rsravanreddy/Mage-VL-MLX` | 動画・streaming の設計参考。parity の根拠にはしない |

第三者移植は end-to-end logit parity が未確認のため、設計と数値の参考にとどめ、
一致検証の基準には使わない。

## 検証の原則

- parity は fixture で確認する。公式 PyTorch 実装を固定入力で実行し、
  中間出力(vision tower、projector、decoder logits)と greedy token 列を
  fixture 化する。fixture の生成環境、commit、入力、生成手順を記録する
- 生成の比較は temperature 0 の greedy で行う
- 数値 gate を stage ごとに事前に定め、満たさない場合は次の stage に進まない。
  gate を変更する場合は、変更理由を lab に記録する
- 観測した事実と、解釈・推測を区別して記述する。失敗した入力、未対応 operation、
  fallback、crash、swap 発生も省略しない
- 性能測定は同一入力で最低 3 回行い、中央値とばらつきを記録する

## Stage と gate

### Stage 0: codec-native 前処理の移植性調査

- 内容: `codec-video-prep` と公式 video 前処理のソースを読み、macOS で
  I frame patch、motion vector、residual energy、patch 選択を同等に再現できるか
  机上評価する。FFmpeg `export_mvs`、PyAV、VideoToolbox など抽出手段ごとに
  可否を整理する
- 成果物: 調査 lab(コード実行なし)
- gate: macOS 上での再現経路を具体的に特定できること。特定できない場合は
  Stage 4 を計画から外すか、目標を再定義してこの文書を更新する

最大の不確実性を最初に潰すため、実装より先にこの stage を行う。

2026-08-05 の調査
([`mage-vl-codec-prep-portability`](../2026/08/05/mage-vl-codec-prep-portability/README.md))
で、gate は条件付き通過とした。`codec-video-prep` は sdist と source repository が
なく macOS native build は不可のため、Stage 4 の目標を「macOS 単体で完結」から
「単一の Mac 上で完結(canvas 生成は ARM64 Linux container の公式 wheel、
下流は macOS の MLX 実装)」へ再定義する。

2026-08-25 の実機検証
([`codec-video-prep-container`](../2026/08/25/codec-video-prep-container/README.md))
で、aarch64 wheel が ARM64 Linux container 上で GPU なしに動作し、
codec asset(canvas、meta.json、npy)を出力することを確認した。
出力の公式環境との一致検証は Stage 4 で行う。

### Stage 1: 静止画 parity

- 内容: 独自実装で Mage-ViT、projector、Qwen3 decoder、画像前処理、重みロード、
  生成ループを構成し、BF16 変換重みで検証する
- gate:
  - 重み key の missing / unused がともに 0
  - vision tower の PyTorch 参照に対する相対誤差 `1.0e-4` 以下、cosine 0.9999 以上
  - 参照画像 3 枚以上 × greedy 64 token が fixture と完全一致
- 量子化(8 bit / 4 bit)checkpoint は完全一致を要求せず、同一 prompt での
  token 一致率と出力差を記録する

2026-08-25 の実測
([`mage-vl-image-baseline`](../2026/08/25/mage-vl-image-baseline/README.md))で、
公式実装の静止画推論が macOS(MPS、bfloat16)で完走することを確認した。
続く device 比較
([`mage-vl-fixture-device`](../2026/08/25/mage-vl-fixture-device/README.md))で、
fixture は MPS bf16 で生成することに決定した。公式実装自身の CPU / MPS 間で
vision tower の cosine は 0.99953 であり、上記の cosine 0.9999 gate は
「MPS 生成 fixture に対して」評価する。greedy 一致は device 間で頑健だった。
移植本体は [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)
で開発する。

### Stage 2: torch-free frame-sampled video

- 内容: PyTorch に依存しない frame sampling と動画前処理を実装する
- gate:
  - frame sampler の出力(選択 frame index と前処理後 pixel 値)が公式実装と一致
  - 8 frame 動画 2 本以上 × greedy 64 token が fixture と完全一致
- 実測: model load time、time to first token、decode token/s、
  MLX allocator peak memory、process peak RSS

### Stage 3: proactive streaming gate

- 内容: streaming Mamba mixer と speak / silent 判定を実装する
- gate:
  - Mamba mixer の最大絶対誤差 `1.0e-5` 以下
  - 参照動画に対する speak / silent timeline が fixture と一致
- 実測: event 発生から speak 判定までの遅延

### Stage 4: codec-native sparse video

- 内容: ARM64 Linux container 上の `codec-video-prep`(公式 wheel)で
  codec asset と参照 fixture を生成し、macOS 側の独自実装で canvas 消費以降の
  経路を実装する。neural engine(DCVC-RT)は CUDA 前提のため対象外とする
- gate: 選択 patch 集合が参照実装と一致すること。完全一致しない場合は
  一致率と差分の原因を記録し、出力 token への影響を評価する
- 実測: 同一動画に対する frame-sampled 経路と codec-native 経路の
  visual token 数、decode 速度、peak memory の比較。Microsoft 報告の
  75% 削減・最大 3.5 倍は環境が異なるため、並記するが直接比較しない

## 測定項目と方法

性能を報告する stage では、次を同一条件で測定する。

- model load time、time to first token、decode token/s
- MLX allocator peak memory、process peak RSS、swap 使用量
- 入力、prompt、max tokens、量子化方式を固定し、同一入力で 3 回測定する

## 環境の記録

各 lab の実行前に次を `output/` に保存する。生成物は Git に追加しない。

```sh
mkdir -p output
sw_vers > output/sw-vers.txt
system_profiler SPHardwareDataType > output/hardware.txt
python -m pip freeze > output/pip-freeze.txt
python -c 'import mlx; print(mlx.__version__)' > output/mlx-version.txt
```

## リスクと制約

- `codec-video-prep` が native extension のみで配布され、アルゴリズムを
  ソースから追えない場合、Stage 4 は成立しない。これは Stage 0 で判定する
- 公式の動画・streaming 経路が `mamba-ssm` や `flash-attn` など CUDA 前提の
  依存を持つ場合、fixture 生成に CUDA 環境が必要になる。CPU で代替できるかは
  Stage 0 で確認する
- upstream の実装と checkpoint は公開直後であり、tag、実装、対応範囲が変わり得る。
  すべての参照を commit hash と revision で固定する
- 静止画の一致から動画、streaming、codec 経路の一致は推論できない。
  各 stage で独立に検証する
