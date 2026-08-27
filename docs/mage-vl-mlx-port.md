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

2026-08-26 時点の回答。

- **再現できた。** 静止画、frame-sampled video、streaming gate、codec-native の
  4 経路すべてで float32 の一致を確認した。ただし streaming gate の SSM は
  参照が自前の再実装である(Stage 3 の節を参照)
- **token 削減は成立するが、比較条件に強く依存する。** カバレッジを揃えれば
  95% 削減、固定 32 frame 予算比で 71% 削減。一方、短いクリップを 8 frame で
  見る既定設定と比べると codec のほうが token は多い。速度も本測定の条件では
  codec が遅い
- **定量的に確認できた。** 動画は前処理が bit 一致し greedy も一致、
  codec は patch 選択が bit 一致した

## 現在の状況(2026-08-27)

移植本体は [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)。

| Stage | 内容 | 状況 |
|---|---|---|
| 0 | codec-native 前処理の移植性 | 条件付き通過。container 経路を実機確認済み |
| 1 | 静止画 parity | float32 で通過 |
| 2 | torch-free frame-sampled video | float32 で通過 |
| 3 | proactive streaming gate | 数値一致は float32 で条件付き通過。機能は codec 経路が前提 |
| 4 | codec-native sparse video | float32 で通過 |

主要な結果。

| 項目 | 結果 |
|---|---|
| 重み key(本体 696 / gate 64) | missing・unused ともに 0 |
| 静止画 vision tower(float32) | 相対誤差 8.9e-06〜1.6e-05、cosine 1.000000 |
| 静止画 greedy 64 token | 3 枚とも完全一致 |
| 動画 前処理 | frame index・grid・patch_positions・pixel values が bit 一致 |
| 動画 greedy 64 token | 3 本とも完全一致 |
| streaming gate mixer | 最大絶対誤差 2.7e-07〜4.4e-07(基準 1.0e-5) |
| codec 前処理 | patch_positions・pixel values が bit 一致 |
| codec greedy 64 token | 2 本とも完全一致 |

実測(M4 Max、bfloat16、greedy 64 token)。

| 経路 | prompt | decode | MLX peak memory |
|---|---:|---:|---:|
| 静止画 | 1,561 token | 21.9 token/s | 9.88 GB |
| 動画 8 frame | 3,159 token | 14.4 token/s | 10.66 GB |
| codec 28 canvas | 5,279 token | 9.6 token/s | 11.81 GB |

### リアルタイム運用の到達点(2026-08-27)

parity とは別に、区間到着ごとに処理する実装で応答遅延と持続性能を測った
([記録](../2026/08/27/mage-vl-realtime-benchmark/README.md))。real-time factor は
media 長に対する処理時間の比で、1 未満でなければ継続入力で遅れが溜まり続ける。

| 機種 | 入力 | 最良の構成 | RTF |
|---|---|---|---:|
| M4 Max | 固定動画 | codec・8 秒 | **0.744** |
| M4 Max | 固定動画 | codec・4 秒 | **0.898** |
| M1 Max | 固定動画 | codec・8 秒 | 1.425 |
| M1 Max | ライブカメラ | codec・4 秒 | **0.62** |
| M1 Max | ライブカメラ | frames・4 秒 | 約 2.1 |

両機の RTF 比は全 8 条件で 1.67〜1.92 倍に収まり、機種差は条件によらずほぼ一定だった。
律速は decode ではなく visual token に対する生成 prefill で、M1 Max の frames では
1 区間 8〜9 秒のうち 6〜7 秒を占める。codec の token 削減はここに直接効く。

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

codec 経路を使う場合は、さらに次を用意する。`codec-video-prep` は
manylinux wheel のみで macOS に install できないが、公式実装は外部バイナリを
`CV_PREINFER_BIN` で差し替えられる。ARM64 Linux container 内の `cv-preinfer` を
呼ぶラッパーを用意し、`--video` と `--out_dir` の絶対パスを container 内の
同じパスに bind mount すれば、**公式実装を無改変のまま macOS で codec 推論できる**。

```sh
docker build --platform linux/arm64 -t mage-cvprep:0.2.5 \
  -f docker/Dockerfile.cvprep docker/
export CV_PREINFER_BIN=$PWD/docker/cv-preinfer
```

生成された codec asset は `ONLINE_CODEC_CACHE_DIR`(既定は
`$HF_HOME/online_codec`)にキャッシュされ、次回以降は再生成されない。

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
- `flash-attn` は 4 経路すべてで不要だった
- upstream の実装と checkpoint は公開直後であり、tag、実装、対応範囲が変わり得る。
  すべての参照を commit hash と revision で固定する
- 静止画の一致から動画、streaming、codec 経路の一致は推論できない。
  各 stage で独立に検証する
- bfloat16 での実行時挙動は公式と一致しない。実用上は動作するが、
  「公式と同一の token 列を出す」ことは bfloat16 では保証されない。
  streaming gate の 2 値判定は特に脆く、`p_speak` が 0.5 付近だと反転する
- **数値一致は機能の正しさを保証しない。** streaming gate は Stage 3 で
  数値一致したにもかかわらず、frames 入力では実イベントに反応しなかった。
  原因は入力表現の不一致で、codec 入力にして初めて発火した。
  経路ごとに、数値だけでなく機能そのものを確認する
- **効率の主張は baseline を明示しないと逆の結論になる。** codec の token 削減は
  カバレッジを揃えれば 95%、固定 32 frame 予算比で 71% だが、
  8 frame 既定との比較では codec のほうが多い
- **codec 経路が受け付けるのは H.264 / HEVC のビットストリームだけ。** 公式
  `cv-preinfer` は bit cost を圧縮ストリームから読むため、MPEG-4 Part 2(OpenCV の
  `mp4v` writer の既定)と VP9 は `KeyError: 'pixels'` で落ちる。動画を自前で書き出して
  codec へ渡す経路を作るときは、必ず H.264 か HEVC で書く。
  **さらに 1 window あたり 8 フレーム以上が必要**で(`--min_group_frames 8`)、
  下回ると `RuntimeError: no canvases produced` になる。ライブ入力では
  `window 秒数 × capture fps` がこれを満たすかを、実行前に検証する
- **codec のコストはフレーム数に段階的にしか反応しない。** `--group_size 32` /
  `--images_per_group 4` の既定では、32 フレームまでは 1 グループ = canvas 4 枚 = 576 token で
  一定であり、2 fps を 8 fps にしても**モデルの負荷は増えない**(前処理が 0.06 秒増えるだけ)。
  32 を超えると canvas が 12、20 と増え、120 フレームでは 1 区間あたり約 3.8 倍になる。
  **`window 秒数 × capture rate` を 32 に寄せる**のが、時間解像度をタダで最大化する設定である
- **ラベルの説明順が検出性能に効く。** ジェスチャ検出で取れなかったラベルが、質問文の中で
  説明を前に移しただけで取れるようになり、しかも低い capture rate でも成立した。
  検出が悪いときは、入力を増やす前にラベル定義の書き方と順序を疑う
- **gate を frames 入力で使ってはいけない。** frames 経路の `p_speak` は
  スポーツでも静止シーンでも 0.0001〜0.013 に張り付く。非ゼロの閾値を設定すると
  全 window が無言で落ちる。gate を pre-filter として使うなら codec 入力が前提であり、
  frames を使うなら閾値は 0 にして生成文だけで判定する
- **MLX peak memory を必要メモリの見積もりに使わない。** 長時間プロセスの macOS
  `footprint` は MLX の buffer cache を含み、peak の 2 倍以上になる。cache は全確保の
  高水位を保持し、処理を止めても解放されない。64 GB 機でも重い設定では swap が
  17 GB まで増えた一方、同時点の MLX peak は 22 GB だった。必要量は
  **実際に使う最大設定での footprint** で見積もり、run の終了時に `mx.clear_cache()` を呼ぶ
- **cold start はマシンにつき 1 回で、プロセスごとではない。** 初回の 1 区間だけ
  約 17 秒の上乗せが出るが、これは 8.8 GB の重みの初回 page-in であり、
  以降は別プロセスでも OS の page cache が効く。プロセス起動ごとの固定費として
  一般化しない
- **ストリームでは codec アセットのキャッシュを使い捨てにする。** `run_cv_preinfer` は
  動画のパス単位でキャッシュし削除しない。ライブ入力は同じ区間を二度処理しないため、
  1 秒 stride なら 1 アセット約 574 KB × 3,600 個/時 = 約 2 GB/時 が溜まるだけになる

## 残る未解決事項

Stage 0〜4 は完了したが、次は未確認のまま残っている。

- ~~streaming gate の発火とイベント時刻の対応~~ →
  **決着した**([記録](../2026/08/26/mage-vl-gate-event-correlation/README.md))。
  対照実験の結果、**gate の確率はイベント時刻を指さない**。gate はコンテンツ種別
  (サッカー中継 0.69〜0.79 対 静かな廊下 0.04〜0.11)を明確に分けるが、
  同じ種別内でイベントの有無は区別せず、シュートを含むセグメントのほうが
  対照より低い値になる例も観測した。
  gate が答えるのは「このストリームは実況に値するか」であり、
  「いま何かが起きたか」ではない。

  ただし**生成文はイベントとその時刻を正しく述べる**。1 秒粒度の追試で、
  グラス落下のクリップは確率が 0.45〜0.52 に団子になる一方、
  生成文は「remains static」系と「Suddenly ... starts to move」系に綺麗に割れた。
  実用上は gate を低い閾値で足切りに使い、判定は生成文で行う
- **`mamba-ssm` の CUDA kernel との一致。** Stage 3 の参照は自前の
  pure PyTorch 再実装であり、公式が実行する kernel との一致は未検証。
  CUDA 環境が使えるようになった時点で確認する
- **実写動画での挙動。** 検証に使った動画はすべて合成または LTX-2 生成である。
  gate の結論(種別には反応、イベント時刻には反応しない)が実写でも成り立つかは未確認
- ~~カメラ入力で gate が使えるか~~ →
  **決着した**([記録](../2026/08/27/mage-vl-realtime-benchmark/README.md))。
  ブラウザが送る 2〜8 fps の JPEG 静止画を H.264 で再エンコードするだけで、
  gate はコンテンツ種別を判別する(スポーツ 0.79〜0.82 対 静止シーン 0.12〜0.14)。
  codec-native の信号は元の 24 fps エンコード固有の性質ではなかった。
  同時に visual token が 79% 減り、M1 Max のライブカメラが RTF 0.62 で
  継続入力に追いつくようになった
- **本物のカメラ圧縮ストリームでの挙動。** 上記の bit cost は、我々が静止画から
  再エンコードした結果であってカメラ本来の圧縮ではない。ブラウザの `MediaRecorder` で
  実際の圧縮ストリームを送る構成(`MediaRecorder` の H.264 は Chrome で利用可能、
  Firefox は VP8 / VP9 のみで `cv-preinfer` が受け付けない)は**見送った**。
  削れるのは再エンコードの 0.09 秒だけで、現行方式でも 8 fps・32 フレームまでは
  モデルの負荷を増やさずに時間解像度を上げられるため、実装コストに見合わないと判断した。
  高いフレームレートが必要になった時点で再検討する
- **`--num_sampled_frames` で時間解像度と canvas 数を切り離せるか。** 32 フレームを超えて
  時間解像度を上げたい場合に canvas 数だけ固定できれば有用だが、この引数が分析前の
  一様間引きであれば時間解像度も一緒に落ちる。必要になった時点で確認する
- ~~公式 segment 分割 protocol と codec 経路の組み合わせ~~ →
  **検証した**(上記 lab)。既定構成で動作する。実行上の注意が 2 件あり、
  末尾の極端に短いセグメントは codec が group を構成できず落ちるため skip する、
  subclip を macOS のシステム temp(`/var/folders`)に置くと Docker から
  見えないためソースと同じ場所に置く。
  なお `--segment-sec` は 1 秒でも動作する(当初「2 秒は不可」としたのは誤りで、
  失敗していたのは末尾の端切れセグメントだけだった)
- **codec 経路の prompt 生成**(`rewrite_text_with_codec_positions`)は未移植。
  parity 検証では公式の `input_ids` を使用した
- **neural engine(DCVC-RT)** は CUDA 前提のため対象外のまま
- **量子化(8 bit / 4 bit)** は未実装・未検証
