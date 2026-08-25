# Mage-VL 独自 MLX 移植の検証方針

この文書は、mlx-vlm に依存しない Mage-VL の独自 MLX 移植を段階的に進めるための
検証方針を定める。調査の前提と用語は
[`2026/08/05/mage-vl-mlx-mac`](../2026/08/05/mage-vl-mlx-mac/README.md) を参照する。
MLX 移植一般の parity 検証手法は
[`mlx-port-parity.md`](mlx-port-parity.md) に分離した。

## 目的と問い

次の点を明らかにする。

- Mage-VL の全機能(静止画、frame-sampled video、proactive streaming、
  codec-native sparse video)を、mlx-vlm に依存しない独立実装として
  MLX で再現できるか
- Mage-VL の主要な特徴である codec-native 経路の visual token 削減と速度向上が、
  Apple Silicon の unified memory 環境でも成立するか
- 動画・streaming 経路について、PyTorch 参照実装との end-to-end 一致を
  定量的に確認できるか。これは 2026-08-05 時点で誰も報告していない

## 現在の状況(2026-08-26)

移植本体は [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)。

| Stage | 内容 | 状況 |
|---|---|---|
| 0 | codec-native 前処理の移植性 | 条件付き通過。container 経路を実機確認済み |
| 1 | 静止画 parity | float32 で通過 |
| 2 | torch-free frame-sampled video | float32 で通過 |
| 3 | proactive streaming gate | 数値一致は float32 で条件付き通過。機能は codec 経路が前提 |
| 4 | codec-native sparse video | float32 で通過 |

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
- **一致検証は float32 で行う**。bfloat16 は実行時精度として扱い、
  gate の判定には使わない。理由は下記「fixture の生成方針」
- 生成の比較は temperature 0 の greedy で行う
- 数値 gate を stage ごとに事前に定め、満たさない場合は次の stage に進まない。
  gate を変更する場合は、変更理由を lab に記録する
- 観測した事実と、解釈・推測を区別して記述する。失敗した入力、未対応 operation、
  fallback、crash、swap 発生も省略しない
- 性能測定は同一入力で最低 3 回行い、中央値とばらつきを記録する

## fixture の生成方針

parity fixture は **CPU float32** で生成する。当初は BF16 変換重みで評価する
計画だったが、2026-08-25 の実測で次が判明したため改めた。

- 異なる backend の bfloat16 同士では一致検証が成立しない。同一実装でも
  MLX と PyTorch-MPS では丸めの累積が異なり、vision tower の cosine は
  0.9988〜0.9992、greedy は 64 token 中 7〜61 しか一致しない
  ([Stage 1](../2026/08/25/mage-vl-mlx-stage1-image-parity/README.md))
- そもそも gate の cosine 0.9999 は、公式実装自身の CPU / MPS 間ですら 0.99953 で
  到達しない([device 比較](../2026/08/25/mage-vl-fixture-device/README.md))
- float32 では同じ実装が相対誤差 `8.9e-06`〜`1.6e-05`、cosine 1.000000、
  greedy 完全一致となる

device と dtype ごとの実測コスト(M4 Max、静止画 1 枚、forward + greedy 64 token)。

| device / dtype | 所要 | 用途 |
|---|---:|---|
| CPU float32 | 約 35 秒 | **parity fixture の生成**(標準) |
| MPS bfloat16 | 約 6 秒 | bfloat16 の参照値が要るときのみ |
| CPU bfloat16 | 約 245 秒 | 使わない(CPU の bf16 は遅い) |
| MPS float32 | ハング | **使わない**(下記) |

MPS float32 は、bf16 → fp32 キャスト(`copy_cast_kernel_mps` 内の Metal shader
dispatch)で進捗なく滞留する。73 分間 swap もメモリ逼迫もない状態で同一スタックに
留まることを確認しているため、待たずに CPU へ切り替える。

## 環境の準備

公式実装を macOS で動かすために必要な対処。いずれも
[Mac ベースライン](../2026/08/25/mage-vl-image-baseline/README.md)で確認した。

- `opencv-python` を install する。checkpoint の remote code は静止画経路でも
  `cv2` を import する
- `mamba_ssm` の stub package を venv に置く。transformers の静的 import 検査
  (`check_imports`)が `streammind_gate.py` の top-level import を見て失敗するため。
  実行時は遅延 import で、静止画・動画経路では呼ばれない。
  stub があると公式 gate は動かないが、Stage 3 では SSM ブロックを
  pure PyTorch で再実装して参照とした(Stage 3 の節を参照)
- checkpoint の revision を固定する。固定しないと `streammind_gate.py` の
  新版が実行時に再ダウンロードされる

## Stage と gate

### Stage 0: codec-native 前処理の移植性調査

- 内容: `codec-video-prep` と公式 video 前処理のソースを読み、macOS で
  I frame patch、motion vector、residual energy、patch 選択を同等に再現できるか
  机上評価する
- gate: macOS 上での再現経路を具体的に特定できること。特定できない場合は
  Stage 4 を計画から外すか、目標を再定義してこの文書を更新する

最大の不確実性を最初に潰すため、実装より先にこの stage を行った。

**結果: 条件付き通過。** `codec-video-prep` は sdist と source repository がなく
macOS native build は不可
([机上調査](../2026/08/05/mage-vl-codec-prep-portability/README.md))。
そのため Stage 4 の目標を「macOS 単体で完結」から
「単一の Mac 上で完結(canvas 生成は ARM64 Linux container の公式 wheel、
下流は macOS の MLX 実装)」へ再定義した。
[実機検証](../2026/08/25/codec-video-prep-container/README.md)で、aarch64 wheel が
ARM64 Linux container 上で GPU なしに動作し、codec asset(canvas、meta.json、npy)を
出力することを確認済み。出力の公式環境との一致検証は Stage 4 で行う。

### Stage 1: 静止画 parity

- 内容: 独自実装で Mage-ViT、projector、Qwen3 decoder、画像前処理、重みロード、
  生成ループを構成する
- gate(float32 で評価する):
  - 重み key の missing / unused がともに 0
  - vision tower の PyTorch 参照に対する相対誤差 `1.0e-4` 以下、cosine 0.9999 以上
  - 参照画像 3 枚以上 × greedy 64 token が fixture と完全一致
- 量子化(8 bit / 4 bit)checkpoint は完全一致を要求せず、同一 prompt での
  token 一致率と出力差を記録する

**結果: 通過**([記録](../2026/08/25/mage-vl-mlx-stage1-image-parity/README.md))。
重み key 696 は missing / unused ともに 0、vision tower の相対誤差
`8.9e-06`〜`1.6e-05`、cosine 1.000000、greedy 64 token は 3 枚とも完全一致。

### Stage 2: torch-free frame-sampled video

- 内容: PyTorch に依存しない frame sampling と動画前処理を実装する
- gate:
  - frame sampler の出力(選択 frame index と前処理後 pixel 値)が公式実装と一致
  - 8 frame 動画 2 本以上 × greedy 64 token が fixture と完全一致
- 実測: model load time、time to first token、decode token/s、
  MLX allocator peak memory、process peak RSS

**結果: 通過**([記録](../2026/08/25/mage-vl-mlx-stage2-video-parity/README.md))。
8 frame のクリップ 3 本で、選択 frame index・grid・patch_positions・pixel values が
bit 単位で一致し、greedy 64 token も 3 本とも完全一致した。

移植で誤りやすい点として次を確認した。Stage 3・4 でも同じ前処理系を使うため、
実装前に確認する。

- `patch_positions` の t 軸は **実 frame 番号**(例 0, 17, 34, …, 119)であり、
  0..T-1 の連番ではない
- `MageVLProcessor` は動画を image 経路に流し、`image_grid_thw` を frame ごとに
  1 行返す。単体の `MageVLVideoProcessor` は merged な `[T, h, w]` を返す。
  pixel values と patch_positions は同一だが、vision tower の `cu_seqlens` が
  変わるため attention 窓が変わる(frame 内で閉じる / 4 frame をまたぐ)。
  移植は公式の推論経路である前者に合わせた

### Stage 3: proactive streaming gate

- 内容: streaming Mamba mixer と speak / silent 判定を実装する
- gate:
  - Mamba mixer の最大絶対誤差 `1.0e-5` 以下
  - 参照動画に対する speak / silent timeline が fixture と一致
- 実測: event 発生から speak 判定までの遅延

**結果: 条件付き通過**([記録](../2026/08/25/mage-vl-mlx-stage3-streaming-gate/README.md))。
mixer に同一入力を与えた最大絶対誤差は `2.7e-07`〜`4.4e-07` で gate を満たし、
speak / silent timeline も 4 本すべてで一致した。

条件は参照の出所である。`mamba-ssm` は macOS に install できない
(setup.py が `torch.version.cuda` を parse し、None で失敗する)ため、
SSM ブロックのみを pure PyTorch で再実装したものを参照とした。
**mamba-ssm の CUDA kernel との一致は未検証**であり、
CUDA 環境が使えるようになった時点で確認する。

あわせて次を確認した。

- 数値 gate が特定の module を指す場合、その module に同一入力を与えて測る。
  end-to-end で測ると上流の誤差を含み、条件の意味が変わる
  (VideoMamba の end-to-end 誤差は `1.2e-05`〜`1.4e-05` で gate を超えるが、
  差は mixer ではなく平均プールと PreNet に由来する)
- **gate の判定は bfloat16 に対して頑健でない。** `p_speak` が 0.5 付近にあるとき、
  bfloat16 の丸めだけで speak / silent が反転する(float32 で 0.5022 の時刻が
  bfloat16 で 0.4977)。判定の再現性が要る用途では float32 で動かす
- ClsNet の rope_theta は Qwen3Config の既定値 10000 で、本体 decoder の 5e6 と異なる

2026-08-25 に実動画で機能面を確認した
([`mage-vl-streaming-event-detection`](../2026/08/25/mage-vl-streaming-event-detection/README.md))。
**frames backend では実イベントを検出しなかった。** ドアが開く、グラスが落ちる、
サッカーのゴールのいずれでも p_speak は 0.0002〜0.0135 にとどまり、
学習ドメインであるはずのサッカーが最も低かった。発火するのは黒画面のみで、
SSM を迂回しても同一値になることから、時間的なイベント検出ではなく
静的な見た目に対する反応と切り分けた。

あわせて評価方法を訂正した。gate は frame ごとではなく、
**セグメント単位**で読む。公式 `inference_streaming.py` は動画を
`segment_sec`(既定 8 秒)で分割し、各セグメントの vision token を連結して
`response_positions` に境界を与え、**境界位置の logits だけ**を softmax する。
公式既定の backend は `codec` である。

「event 発生から speak 判定までの遅延」は未測定のまま。発火しないため測れない。
最有力の仮説は入力表現の不一致(gate は codec canvas の token で学習された)であり、
これは [Stage 4](../2026/08/26/mage-vl-mlx-stage4-codec-native/README.md) で裏付けられた。
codec 入力にすると同じ動画で `p_speak` の最大値が 0.0009 → 0.8139(サッカー)に変わる。
**gate は codec 経路を前提としている。**

### Stage 4: codec-native sparse video

- 内容: ARM64 Linux container 上の `codec-video-prep`(公式 wheel)で
  codec asset と参照 fixture を生成し、macOS 側の独自実装で canvas 消費以降の
  経路を実装する。neural engine(DCVC-RT)は CUDA 前提のため対象外とする
- gate: 選択 patch 集合が参照実装と一致すること。完全一致しない場合は
  一致率と差分の原因を記録し、出力 token への影響を評価する
- 実測: 同一動画に対する frame-sampled 経路と codec-native 経路の
  visual token 数、decode 速度、peak memory の比較。Microsoft 報告の
  75% 削減・最大 3.5 倍は環境が異なるため、並記するが直接比較しない

**結果: 通過**([記録](../2026/08/26/mage-vl-mlx-stage4-codec-native/README.md))。
patch_positions と pixel values が公式と bit 一致し、greedy 64 token も一致した。

macOS で codec 経路を動かす方法も確立した。公式実装は外部バイナリを
`CV_PREINFER_BIN` で差し替えられるため、ARM64 Linux container 内の
`cv-preinfer` を呼ぶラッパーを用意すれば、**公式実装を無改変のまま
macOS で codec 推論できる**。Stage 0 で構想した経路が、参照側も
Mac ネイティブのまま成立した。

token 効率は**比較条件を明示しないと逆の結論になる**。均等サンプリングは
frame 数によらず 1 frame あたり 384 visual token で一定なのに対し、
codec は 193 frame 中 192 frame を 3,528 token(1 frame あたり 18.4)でカバーする。
カバレッジを揃えれば 95% 削減、固定 32 frame 予算比では 71% 削減。
一方、8 秒クリップを 8 frame で見る既定設定と比べると codec のほうが token は多い。

## 測定項目と方法

性能を報告する stage では、次を同一条件で測定する。

- model load time、time to first token、decode token/s
- MLX allocator peak memory、process peak RSS、swap 使用量
- 入力、prompt、max tokens、量子化方式を固定し、同一入力で 3 回測定する

参考値(M4 Max、bfloat16、greedy 64 token、3 回の中央値)。

| 経路 | prompt | decode | MLX peak memory |
|---|---:|---:|---:|
| 静止画 | 1561 token | 21.9 token/s | 9.88 GB |
| 動画 8 frame | 3159 token | 14.4 token/s | 10.66 GB |

比較対象として、公式 PyTorch の MPS bfloat16 は 16.7 token/s(RSS 9.44 GB)、
mlx-vlm 0.6.15 の 8bit は 91.5 token/s(6.83 GB)。8bit は量子化しており
条件が異なるため直接比較しない。

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

- 公式 streaming 経路は `mamba-ssm` を要求し、macOS では動かない。
  Stage 3 は SSM ブロックの pure PyTorch 再実装を参照として通過させたため、
  公式 CUDA kernel との一致は未検証のまま残る
- `flash-attn` は静止画・動画経路では不要だった。streaming・codec 経路で
  必要になるかは未確認
- upstream の実装と checkpoint は公開直後であり、tag、実装、対応範囲が変わり得る。
  すべての参照を commit hash と revision で固定する
- 静止画の一致から動画、streaming、codec 経路の一致は推論できない。
  各 stage で独立に検証する
- bfloat16 での実行時挙動は公式と一致しない。実用上は動作するが、
  「公式と同一の token 列を出す」ことは bfloat16 では保証されない
