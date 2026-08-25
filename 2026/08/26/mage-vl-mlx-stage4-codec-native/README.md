# Mage-VL 独自 MLX 移植 Stage 4: codec-native sparse video

Mage-VL の MLX 移植シリーズの最終 stage です。
Mage-VL の中心的な特徴である codec-native sparse video 経路を MLX で実装し、
一致検証と token 効率の測定を行いました(2026-08-26)。
前段は [Stage 3](../../25/mage-vl-mlx-stage3-streaming-gate/README.md) と、
機能面の未解決を残した
[streaming gate の実動画検証](../../25/mage-vl-streaming-event-detection/README.md)です。

**この stage で 2 つのことが同時に片付きました。** codec 経路の一致検証に加え、
前回「frames backend では streaming gate が実イベントを検出しない」と記録した
未解決の仮説が、codec 入力で発火することで裏付けられました。

## 目的と問い

- codec-native 経路を macOS で実行し、独自実装で再現できるか
- Stage 4 の gate: 選択 patch 集合が参照実装と一致するか
- codec-native の visual token 削減は Apple Silicon で成立するか
- (積み残し)streaming gate が発火しないのは入力表現が原因か

## macOS で codec 経路を動かす方法

`codec-video-prep` は manylinux wheel のみで macOS に install できません
([Stage 0](../../05/mage-vl-codec-prep-portability/README.md))。
一方、公式の codec 実装は外部バイナリ `cv-preinfer` を
**`CV_PREINFER_BIN` 環境変数で差し替え可能**でした。

そこで、ARM64 Linux container 内の `cv-preinfer` を呼ぶラッパースクリプトを用意し、
`--video` と `--out_dir` の絶対パスを container 内の同じパスに bind mount しました。
これにより引数がそのまま通り、**macOS 上の公式 PyTorch 実装が codec 経路を
無改変で実行できます**。

```sh
docker build --platform linux/arm64 -t mage-cvprep:0.2.5 \
  -f docker/Dockerfile.cvprep docker/
export CV_PREINFER_BIN=$PWD/docker/cv-preinfer
```

Stage 0 で構想した「container で生成、Mac で消費」が、
参照実装の側も Mac ネイティブのまま成立しました。
4.7B のモデルを container 内で走らせる必要はありません。

## 実行方法

移植本体は [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)
commit `a49e48e` です。

```sh
git clone https://github.com/kiarina/mage-vl-mlx && cd mage-vl-mlx
git checkout a49e48e
uv sync --group fixtures
.venv/bin/python scripts/install_mamba_stub.py
.venv/bin/python scripts/convert_weights.py
docker build --platform linux/arm64 -t mage-cvprep:0.2.5 -f docker/Dockerfile.cvprep docker/
export CV_PREINFER_BIN=$PWD/docker/cv-preinfer

M=$HOME/.cache/huggingface/modules/transformers_modules/microsoft/Mage_hyphen_VL/d88b153285f1633a61b2f693c59c8576693af185
PYTHONPATH=$M .venv/bin/python scripts/check_codec_preprocess.py --video V.mp4
PYTHONPATH=$M .venv/bin/python scripts/check_codec_parity.py --video V.mp4
```

## 検証条件

- 動画: [前 lab](../../25/mage-vl-streaming-event-detection/README.md) の
  LTX-2 生成 3 本(768x512、24 fps、193 frame)と、Stage 2 の `pan_objects`
- codec 設定: `patch=16`、`max_pixels=150000`、engine `hevc`
- 参照: `microsoft/Mage-VL` revision `d88b153`、float32、CPU
- 環境: Apple M4 Max、128 GB、macOS 26.5.2、Docker 29.7.2、mlx 0.32.1

## 観測した事実

### 前処理は bit 完全一致(gate)

codec asset directory(canvas + `src_patch_position.npy` + `meta.json`)から
tensor を組み立てる部分を NumPy と PIL だけで実装し、公式と比較しました。

| 動画 | canvas 数 | grid | patch_positions | pixel_values |
|---|---:|---|---|---|
| soccer_goal | 28 | 一致 | **bit 一致** | **bit 一致**(max_abs 0.0) |
| door_open | 28 | 一致 | **bit 一致** | **bit 一致**(max_abs 0.0) |
| pan_objects | 16 | 一致 | **bit 一致** | **bit 一致**(max_abs 0.0) |

Stage 4 の gate は「選択 patch 集合が参照実装と一致すること」であり、
`patch_positions` が bit 一致したことでこれを満たします。
patch 選択自体は container 内の `cv-preinfer` が行い、両者が同じ asset を読むため
構成上一致します。本実装が検証したのは**消費側**です。

### end-to-end 生成も一致

| 動画 | canvas | visual token | prompt | logits cosine | greedy |
|---|---:|---:|---:|---:|---:|
| soccer_goal | 28 | 3528 | 5279 | 1.000000 | 64/64 一致 |
| pan_objects | 16 | 2016 | 2876 | 1.000000 | 64/64 一致 |

生成内容も妥当でした。soccer_goal は
"The video captures an intense soccer match, beginning with a player in a gray
uniform dribbling the ..." と出力しています。

### token 効率: カバレッジを揃えて比較する

`soccer_goal`(193 frame)で、frames backend の frame 数を変えて測りました。

| 設定 | 単位数 | 見た source frame | visual token | token / 見た frame |
|---|---:|---:|---:|---:|
| frames 既定(8 frame) | 8 | 8 | 3,072 | 384.0 |
| frames fps=2 上限16 | 16 | 16 | 6,144 | 384.0 |
| frames fps=4 上限32 | 32 | 32 | 12,288 | 384.0 |
| frames fps=8 上限64 | 64 | 64 | 24,576 | 384.0 |
| frames fps=24 上限193 | 193 | 193 | 74,112 | 384.0 |
| **codec(28 canvas)** | 28 | **192** | **3,528** | **18.4** |

均等サンプリングは frame 数によらず **1 frame あたり 384 token** で一定です。
codec は 193 frame 中 192 frame を 3,528 token でカバーし、
**1 frame あたり 18.4 token(95% 削減)**でした。

固定 32 frame 予算(12,288 token)との比較では **71% 削減**しつつ、
見ている source frame は 6 倍になります。

一方、**8 秒クリップを 8 frame で見る既定設定との比較では codec のほうが
token が多くなります**(3,528 対 3,072)。削減は「絶対数」ではなく
「カバレッジあたり」で効くという性質です。

### 速度は codec のほうが遅い(この条件では)

bfloat16、greedy 64 token での実測です。

| 動画 | backend | visual token | prompt | decode |
|---|---|---:|---:|---:|
| soccer_goal | frames(8) | 3,072 | 3,159 | 12.6 token/s |
| soccer_goal | codec | 3,528 | 5,279 | 9.6 token/s |
| door_open | frames(8) | 3,072 | 3,159 | 14.3 token/s |
| door_open | codec | 3,528 | 4,694 | 10.7 token/s |
| glass_fall | frames(8) | 3,072 | 3,159 | 14.3 token/s |
| glass_fall | codec | 3,528 | 4,550 | 11.0 token/s |

prompt が長い分だけ素直に遅くなっています。Microsoft は codec 経路で
最大 3.5 倍の高速化を報告していますが、それは同等の理解に必要な
frame 数どうしの比較と解釈され、本測定の条件(8 frame との比較)とは異なります。
数値を直接比較しません。

### 積み残しだった streaming gate の仮説が裏付けられた

[前 lab](../../25/mage-vl-streaming-event-detection/README.md) で
「frames backend では実イベントを検出しない。最有力の仮説は入力表現の不一致」と
記録した点を、codec 入力で確認しました。float32、閾値 0.5 です。

| 動画 | frames backend の max | codec backend の max | codec で speak |
|---|---:|---:|---:|
| soccer_goal | 0.0009 | **0.8139** | 8 / 28 canvas |
| glass_fall | 0.0034 | **0.8173** | 5 / 28 canvas |
| door_open | 0.0135 | 0.3351 | 0 / 28 canvas |

学習ドメインであるサッカーが frames では最低(0.0009)だったのに対し、
codec では最も明確に発火します。**入力表現が原因だった**と言えます。

発火位置には構造がありました。canvas は 4 枚で 1 グループを成し、
`4k` 番目は単一時刻(I frame)、`4k+1..4k+3` は複数時刻にまたがります(P frame)。
speak はほぼ**各グループ末尾の canvas**(index 3, 7, 11, 15, 19, 23, 27)に
集中しました。

soccer_goal の canvas 別 `p_speak`(抜粋):

| canvas | 時刻範囲 | p_speak |
|---:|---|---:|
| 3 | 0.71-1.00s | 0.7231 |
| 7 | 1.62-1.83s | 0.6563 |
| 11 | 3.46-4.50s | 0.8139 |
| 15 | 5.21-5.33s | 0.7029 |
| 19 | 5.71-5.88s | 0.7072 |
| 23 | 6.54-6.96s | 0.7116 |
| 27 | 7.62-8.00s | 0.7452 |

## 解釈と評価

- **Stage 4 は float32 で通過**と判断する。patch 選択(patch_positions)と
  pixel values が bit 一致し、greedy も完全一致した
- `CV_PREINFER_BIN` による差し替えは、Stage 0 で「container で生成し Mac で消費」と
  構想した経路を、参照実装を書き換えずに実現する。macOS で codec 経路が
  動いた報告は確認できていない
- token 効率の主張は**比較条件を明示しないと逆の結論になる**。
  「codec は token を削減する」は、カバレッジを揃えた場合(95% 削減)や
  固定 frame 予算との比較(71% 削減)では成立するが、
  短いクリップを 8 frame で見る既定設定と比べると codec のほうが多い。
  Microsoft の 75% という数字がどの baseline に対するものかは論文本文を
  精査していないため、本測定と直接は比較しない
- **streaming gate は codec 経路を前提としている。** frames 入力での沈黙は
  実装の誤りでも protocol の誤りでもなく、入力表現の不一致だった。
  これで前 lab の仮説が裏付けられた
- ただし「特定シーンの検出」が実現したとまでは言えない。発火は
  グループ末尾という構造的な位置に集中しており、
  イベント時刻との対応は確認できていない(下記)

## 未確認事項と制約

- 発火とイベント時刻の対応は、続く
  [対照実験](../mage-vl-gate-event-correlation/README.md)で決着した。
  **発火はイベント時刻に追随せず、コンテンツ種別に反応している**
- door_open は codec でも閾値を超えない(max 0.3351)。ドメイン依存が残る
- 公式 `inference_streaming.py` の segment 分割 protocol と組み合わせた
  codec 経路は未検証。本 lab は動画全体を 1 回で処理している
- prompt 文字列の生成(`rewrite_text_with_codec_positions`)は移植していない。
  parity 検証では公式の `input_ids` を使用した。移植側単体で codec 推論を
  完結させるには未実装
- neural engine(DCVC-RT)は対象外。CUDA 前提のため
- 検証動画は LTX-2 生成で実写ではない。canvas の内容と patch 選択が
  実写でどうなるかは未確認
- token 効率は 1 本(193 frame)での測定。長尺動画では
  `target_canvas=32` の上限に達し、比率が変わる可能性がある
- 速度測定は bfloat16。bfloat16 では公式と同一 token 列を出す保証はない

## 参照

シリーズの前の研究:

- [streaming gate は実動画のイベントを検出するか](../../25/mage-vl-streaming-event-detection/README.md)(2026-08-25)
- [Stage 3: proactive streaming gate parity](../../25/mage-vl-mlx-stage3-streaming-gate/README.md)(2026-08-25)
- [Stage 2: torch-free frame-sampled video parity](../../25/mage-vl-mlx-stage2-video-parity/README.md)(2026-08-25)
- [codec-video-prep の container 実機検証](../../25/codec-video-prep-container/README.md)(2026-08-25)
- [Mage-VL codec-native 前処理の macOS 移植性調査](../../05/mage-vl-codec-prep-portability/README.md)(2026-08-05)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)

外部:

- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)(移植リポジトリ)
- [codec-video-prep on PyPI](https://pypi.org/project/codec-video-prep/)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
