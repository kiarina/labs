# Mage-VL 独自 MLX 移植 Stage 2: torch-free frame-sampled video parity

Mage-VL の MLX 移植シリーズの検証です。
[検証方針](../../../../docs/mage-vl-mlx-port.md)の Stage 2 として、
PyTorch に依存しない frame sampling と動画前処理を実装し、
公式実装との一致を検証しました(2026-08-25)。
前段は [Stage 1: 静止画 parity](../mage-vl-mlx-stage1-image-parity/README.md) です。

## 目的と問い

- 動画の decode、frame 選択、resize、patch 化を PyTorch なしで実装し、
  公式実装と一致させられるか
- Stage 2 の gate を満たすか
  - frame sampler の出力(選択 frame index と前処理後 pixel 値)が公式実装と一致
  - 8 frame 動画 2 本以上 × greedy 64 token が fixture と完全一致
- 静止画で判明した bfloat16 の制約は、動画でも同様か

## 実行方法

移植本体は [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)
commit `f09bbbc` です。

```sh
git clone https://github.com/kiarina/mage-vl-mlx
cd mage-vl-mlx && git checkout f09bbbc
uv sync --group fixtures
.venv/bin/python scripts/install_mamba_stub.py
.venv/bin/python scripts/convert_weights.py

# 検証用クリップを共有アセットから生成する
scripts/make_testdata.sh /path/to/labs/tests/assets/jpg

.venv/bin/python scripts/check_video_preprocess.py \
  --video testdata/pan_objects.mp4 --video testdata/street_ocr.mp4 \
  --video testdata/faces_odd.mp4
.venv/bin/python scripts/generate_video_fixtures.py \
  --video testdata/pan_objects.mp4 --video testdata/street_ocr.mp4 \
  --video testdata/faces_odd.mp4 --device cpu --dtype float32
.venv/bin/python scripts/check_video_parity.py \
  --video testdata/pan_objects.mp4 --video testdata/street_ocr.mp4 \
  --video testdata/faces_odd.mp4 --device cpu --dtype float32
```

## 検証条件

検証用の動画 3 本は、labs の共有アセット(jpg)から ffmpeg で決定的に生成します。
生成物は Git に追加せず、上記 script で再生成します。

| クリップ | 内容 | 解像度 | 長さ |
|---|---|---|---|
| `pan_objects` | `objects_1536x1024` を pan / zoom | 768x512 | 4 秒 / 120 frame |
| `street_ocr` | `street_scene` と `ocr` を連結 | 768x512 | 4 秒 / 120 frame |
| `faces_odd` | `many_face` を pan / zoom | **700x460** | 3 秒 / 90 frame |

`faces_odd` は 32 の倍数でない解像度にして、resize 経路を通しています。

- prompt `Describe this video.`、greedy、64 token
- 参照: `microsoft/Mage-VL` revision `d88b153`、float32、CPU
- 環境: Apple M4 Max、128 GB、macOS 26.5.2、torch 2.13.0、transformers 5.15.1、
  mlx 0.32.1、opencv-python

## 実装の要点

公式は decord 優先・OpenCV fallback ですが、本環境には decord がないため
OpenCV 経路が使われます。移植はこの経路に合わせ、OpenCV / NumPy / PIL のみで
実装しました。

- frame 数の決定: 10 秒未満は 8 frame、30 秒未満は 16、それ以上は `max_frames`
- frame 選択: `linspace(0, frame_count-1, target)` を round。
  torch と numpy はどちらも偶数丸めのため一致する
- resize: `smart_resize` の align は `patch_size * 2` = 32。縮小を含む場合は
  `INTER_AREA`、拡大のみなら `INTER_LINEAR`
- 正規化: transformers は rescale 係数を mean / std に畳み込み、
  0..255 の値をそのまま正規化する。この順序に合わせて初めて bit 一致した
  (素直に `x/255` してから正規化すると最大 4.77e-07 ずれる)
- patch 化: Qwen2VL の `reshape → transpose(0,2,5,3,6,1,4,7) → reshape`

## 観測した事実

### 前処理は bit 完全一致(gate 1)

3 本すべてで、選択 frame index、grid、patch_positions、pixel values が
公式実装と **bit 単位で一致**しました(最大絶対差 0.0)。
resize を伴う `faces_odd` も一致しています。

### greedy は 3 本すべて完全一致(gate 2)

float32 CPU fixture に対する結果。

| クリップ | 前処理 | vision 相対誤差 | logits 相対誤差 | greedy |
|---|---|---:|---:|---:|
| pan_objects | bit 一致 | 3.606e-04 | 1.111e-04 | 64/64 一致 |
| street_ocr | bit 一致 | 1.820e-05 | 4.474e-05 | 64/64 一致 |
| faces_odd | bit 一致 | 8.892e-06 | 1.057e-05 | 64/64 一致 |

`pan_objects` の vision 相対誤差 3.6e-04 は、Stage 1 の静止画(8.9e-06〜1.6e-05)
より一桁大きい。Stage 2 の gate は vision の数値閾値を定めていないため gate 判定には
影響しないが、事実として記録する。cosine は 3 本とも 1.000000 で、greedy は一致した。

生成内容も妥当でした(公式 float32 CPU の出力):

- pan_objects: "The video presents a serene and organized workspace, featuring a
  wooden desk positioned near a window..."
- faces_odd: "The video captures a bustling scene in a busy city, likely in Japan,
  as indicated by the presence of Japanese..."

### 移植で踏むと壊れる 2 点

いずれも実装中に実際に判明し、検証で確定させたものです。

1. **`patch_positions` の t 軸は実 frame 番号**である。
   8 frame の場合 `[0, 17, 34, 51, 68, 85, 102, 119]` であり、
   0..T-1 の連番ではない。公式 docstring は training pipeline の規約と説明する
2. **`MageVLProcessor` は動画を image 経路に流し、`image_grid_thw` を
   frame ごとに 1 行**(`[1, 32, 48]` × 8)で返す。
   一方 `MageVLVideoProcessor` を単体で呼ぶと `[[8, 32, 48]]` の 1 行を返す。
   pixel values と patch_positions は両者で完全に同一だが、
   vision tower の `cu_seqlens` が変わるため **attention の窓が変わる**。
   前者は frame 内で閉じた attention、後者は `frame_windows_size=4` により
   4 frame をまたぐ attention になる。
   本移植は公式の推論経路である前者に合わせた

### 性能(参考)

bfloat16、8 frame、prompt 3159 token、greedy 64 token、3 回測定。

| 経路 | decode | peak memory | 前処理 |
|---|---:|---:|---:|
| 動画 8 frame | 14.4 token/s | 10.66 GB | 0.15 秒 |
| 静止画(Stage 1) | 21.9 token/s | 9.88 GB | - |

### 失敗した試行

- 最初は `x * (1/255)` してから正規化したため、pixel values が
  最大 4.77e-07(float32 の 1 ULP 相当)ずれ、bit 一致しなかった。
  transformers の融合順序に合わせて解消した
- fixture 生成 script は当初 `pixel_values_videos` / `video_grid_thw` を
  読もうとして失敗した。上記のとおり、トップレベル processor は
  `pixel_values` / `image_grid_thw` を返す

## 解釈と評価

- **Stage 2 は float32 で通過**と判断する。gate 2 つをともに満たした
- 前処理が bit 一致したことは、frame 選択・resize・正規化・patch 順序という
  誤りが混入しやすい部分がすべて正しいことを意味する。
  resize を伴うクリップでも一致したため、OpenCV の補間まで含めて公式と同一である
- bfloat16 については、[Stage 1](../mage-vl-mlx-stage1-image-parity/README.md) で
  確定した制約(backend 間の丸め差により一致検証に使えない)がそのまま当てはまると
  考える。動画で改めて bfloat16 の greedy 一致は測定していない
- `image_grid_thw` の 2 つの表現が attention 窓を変える点は、
  公式実装内部の不整合と解釈しうる。どちらが設計意図かは判断できないため、
  推論経路に合わせるという方針だけを採った

## 未確認事項と制約

- 検証は 8 frame、3 本、単一 prompt、64 token のみ。16 / 32 frame、長尺動画、
  `target_fps` 指定、複数動画の同時入力は未検証
- 入力は共有アセットの静止画から合成したクリップであり、実写動画ではない。
  カメラの動き、圧縮由来の劣化、シーン切り替えの多様性は限定的
- decord がある環境では公式は decord 経路(torchvision BICUBIC)を使うため、
  本移植の OpenCV 経路と一致しない可能性がある。未検証
- bfloat16 での動画 greedy 一致率は未測定
- `image_grid_thw` を merged 形式にした場合の出力差は測定していない
- streaming gate と codec 経路は引き続き未実装

## 参照

シリーズの前の研究:

- [Stage 1: 静止画 parity](../mage-vl-mlx-stage1-image-parity/README.md)(2026-08-25)
- [parity fixture の生成 device 比較](../mage-vl-fixture-device/README.md)(2026-08-25)
- [Mage-VL 静止画推論の Mac ベースライン](../mage-vl-image-baseline/README.md)(2026-08-25)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)

外部:

- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)(移植リポジトリ)
- [mlx-vlm frame-sampled video issue 1766](https://github.com/Blaizzy/mlx-vlm/issues/1766)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
