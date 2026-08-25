# Mage-VL streaming gate は実動画のイベントを検出するか

Mage-VL の MLX 移植シリーズの検証です。
[Stage 3](../mage-vl-mlx-stage3-streaming-gate/README.md) で
proactive streaming gate の数値一致は確認できましたが、
**機能が意図どおり働くこと**(映像中の特定シーンを検出して発火すること)は
未確認のまま残っていました。この lab はそこを直接確かめます(2026-08-25)。

結論を先に書くと、**frames backend では実イベントを検出しませんでした。**
発火したのは黒画面という退化した入力のみで、これは時間的なイベント検出ではなく
静的な見た目に起因することを切り分けました。

## 目的と問い

- gate は実動画の「イベント」(ドアが開く、物が落ちる、ゴールが決まる)で
  発火するか
- 発火する場合、イベント発生から speak 判定までの遅延はどれだけか
  (Stage 3 で未測定だった項目)
- 発火しない場合、原因は実装か、入力表現か、ドメインか

## 検証条件

### 検証用動画

LTX-2(kiapi)で生成した 768x512、24 fps、193 frame(8.04 秒)の動画 3 本。
model `distilled`、seed 1234、`generate_audio=false`。プロンプト全文と生成
スクリプトは `output/videos/gen.sh`、`gen2.sh` に保存しています。

イベント発生時刻は、生成後にフレームを目視して注記しました。

| 動画 | イベント | 発生時刻(目視) |
|---|---|---|
| `door_open` | 閉じたドアが開き、明るい部屋が見える | frame 160-164、t ≈ 6.7 秒 |
| `glass_fall` | テーブル端のグラスが落下する | frame 144-168、t ≈ 6.0-7.0 秒 |
| `soccer_goal` | サッカー中継。ゴール前でシュート、GK が跳ぶ | frame 144-192、t ≈ 6.0-8.0 秒 |

`soccer_goal` は gate の学習ドメイン(スポーツ中継)に合わせた対照です。

陽性対照として、Stage 3 で発火が確認済みの `cut_event`
(黒画面 1.5 秒 → 静止画へのハードカット)を使いました。

### 実行条件

- 移植本体 [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)、float32
- 閾値 0.5(公式 `inference_streaming.py` の既定値)
- 環境: Apple M4 Max、128 GB、macOS 26.5.2、mlx 0.32.1

## 実行方法

```sh
cd mage-vl-mlx
.venv/bin/python scripts/gate_stream.py --video path/to/door_open.mp4 --segment-sec 2
```

## 検証用動画の入手

LTX-2 で生成した動画は共有アセットに登録済みです。
生成スクリプトは残していますが、LTX-2 の出力は環境やモデル版で変わりうるため、
**追試には共有アセットを使ってください。**

```sh
make download-test-assets   # または mise run //:test-assets:download
```

| 本文中の呼称 | 取得後のパス |
|---|---|
| `door_open` | `tests/assets/mp4/door_open_768x512_24fps_8s_302kb.mp4` |
| `door_static` | `tests/assets/mp4/door_static_768x512_24fps_8s_397kb.mp4` |
| `glass_fall` | `tests/assets/mp4/glass_fall_768x512_24fps_8s_490kb.mp4` |
| `soccer_goal` | `tests/assets/mp4/soccer_goal_768x512_24fps_8s_1469kb.mp4` |
| `soccer_idle` | `tests/assets/mp4/soccer_idle_768x512_24fps_8s_1422kb.mp4` |

生成時のプロンプト全文と設定は上記「検証条件」に記録しています。

## 観測した事実

### 評価方法の訂正: gate はセグメント単位で読む

当初、gate を frame ごとに読んでいましたが、公式 `inference_streaming.py` を
読んだところ実際の使い方が異なりました。

1. 動画を `segment_sec`(既定 8 秒)の非重複セグメントに分割し、
   各セグメントを**別クリップとして独立に前処理**する
2. 全セグメントの vision token を時間方向に連結して 1 本の因果ストリームにする
3. `response_positions` にセグメント境界を与えて gate を 1 回だけ実行する
4. **境界位置の logits だけ**を softmax して、セグメントごとに 1 つの確率を得る
5. 閾値 0.5 を超えたセグメントについてのみ本体 VLM の生成を走らせる

つまり gate は「この 8 秒について喋るべきか」を判定する**セグメント単位の判断器**で、
frame ごとのイベント検出器ではありません。以降はこの protocol に合わせています。
公式既定の `--video_backend` は **`codec`** であることも確認しました。

### 実イベントでは発火しない

セグメント長 2 秒での結果です。イベントを含むセグメントを太字にしています。

| 動画 | 0-2s | 2-4s | 4-6s | **6-8s** | max |
|---|---:|---:|---:|---:|---:|
| door_open | 0.0135 | 0.0056 | 0.0026 | **0.0068** | 0.0135 |
| glass_fall | 0.0022 | 0.0005 | 0.0008 | **0.0033** | 0.0034 |
| soccer_goal | 0.0009 | 0.0007 | 0.0001 | **0.0002** | 0.0009 |

いずれも閾値 0.5 に遠く、イベントを含むセグメントが突出することもありません。
`door_open` はセグメント長 8 秒・2 秒・1 秒でも、frame ごとの読み方
(既定 8 frame、`target_fps=4` の 32 frame)でも発火しませんでした。

**学習ドメインであるはずのサッカー中継が最も低い**(0.0009)ことは注目に値します。

### 陽性対照は発火する

同じ protocol で `cut_event` は最初のセグメントが speak になりました。

| セグメント | 0-1s(黒画面) | 1-2s | 2-3s | 3-3.03s |
|---|---:|---:|---:|---:|
| p_speak | **0.7206** | 0.0036 | 0.0013 | 0.0002 |

pipeline 自体は speak 判定を出せます。実イベントで発火しないのは
実装や protocol の不備ではありません。

### 発火の正体は静的な見た目

SSM を迂回して(PreNet → PostNet → ClsNet のみ)同じ入力を流しました。

| 入力 | SSM あり | SSM 迂回 |
|---|---|---|
| cut_event | 0.5022, 0.7206, 0.5006, 0.8958, 0.0009, 0.0004, 0.0006, 0.0001 | **0.5607, 0.5607, 0.5607, 0.5607**, 0.0, 0.0, 0.0001, 0.0 |
| pan_objects | 0.0013, 0.0035, 0.0014, 0.0077, 0.0137, 0.0049, 0.0138, 0.0022 | 0.0009, 0.0006, 0.0004, 0.0004, 0.0015, 0.0005, 0.0017, 0.0002 |

黒画面の 4 時刻は SSM を通さないと**完全に同一値 0.5607** になります。
黒フレームの pooled 特徴が同一であるためで、判定は時間的な変化ではなく
その時刻の静的な見た目だけで決まっています。SSM はその値を上下に変調しますが
(0.5607 → 0.5022〜0.8958)、閾値超えの主因ではありません。

この切り分けには重要な副産物があります。SSM を除いた経路
(PreNet、PostNet、4 層 Qwen3)は**公式の重みと stock の transformers** であり、
[Stage 3](../mage-vl-mlx-stage3-streaming-gate/README.md) の留保だった
「SSM が自前の再実装」の影響を受けません。それでも実コンテンツのスコアは
0.001 前後にとどまるため、**低スコアは移植の SSM 実装に起因しない**と言えます。

## 解釈と評価

- **frames backend では、この gate は実動画のイベント検出器として機能しない。**
  ドア、落下、ゴールのいずれも検出せず、学習ドメインのサッカーが最も低かった
- 発火は黒画面という退化入力に対する反応であり、イベント検出ではない。
  SSM 迂回で同一値になることがその証拠である
- 最有力の仮説は**入力表現の不一致**である。公式 streaming の既定 backend は
  `codec` であり、gate は codec canvas から作られた token で学習された可能性が高い。
  frames backend の visual token は分布が異なるため、gate が意味のある応答を
  返さないと考えられる。これは Stage 4 を実装しないと検証できない
- 副次的な仮説として、LTX-2 生成動画が実写と分布が異なる可能性、
  8 秒という短さが gate の想定する文脈長に満たない可能性がある。いずれも未検証
- 実装起因である可能性は、上記の SSM 迂回により大きく下がった。
  ただし完全には否定できない(vision tower の出力そのものが誤っていれば、
  Stage 1・2 の parity を通っていても gate 用の表現としては不適切になりうる)

## 続報(2026-08-26)

この仮説は [Stage 4](../../26/mage-vl-mlx-stage4-codec-native/README.md) で
裏付けられました。codec 入力にすると同じ動画で `p_speak` の最大値が
soccer_goal 0.0009 → 0.8139、glass_fall 0.0034 → 0.8173 に変わり、
閾値 0.5 を超えて発火します。**gate は codec 経路を前提としていました。**
ただし発火は codec グループ末尾という構造的な位置に集中しており、
イベント時刻との対応は引き続き未確認です。

## この結果が計画に与える影響

「機能が動くこと」を優先する方針の下では、次の一手は **Stage 4(codec-native)** になります。
frames backend で打てる手を出し尽くしており、残る最有力仮説の検証に
codec 経路が必要だからです。目的は変わらず streaming の実現ですが、
そこへ至る経路として Stage 4 が前提条件になった、という位置づけです。

## 未確認事項と制約

- **codec backend は未検証。** 公式 streaming の既定であり、最有力仮説そのもの
- イベント発生から speak 判定までの遅延は測定できていない。発火しないため
- 検証動画は LTX-2 生成であり実写ではない。実写中継での挙動は未確認
- 動画は 3 本、各 8 秒のみ。より長い文脈、連続する複数イベントは未検証
- 閾値は公式既定の 0.5 を使用。別の τ を使えば低いスコアでも発火しうるが、
  0.001 と 0.0002 の差にイベントとの相関が見えないため、
  閾値調整で解決する見込みは薄いと考える
- 生成動画は共有アセットに登録済み(上記「検証用動画の入手」)。
  LTX-2 の出力は環境をまたいで再現する保証がないため、追試では
  生成スクリプトではなく共有アセットを使うこと
- gate の学習データと想定運用は公開情報からは詳細不明

## 参照

シリーズの前の研究:

- [Stage 3: proactive streaming gate parity](../mage-vl-mlx-stage3-streaming-gate/README.md)(2026-08-25)
- [Stage 2: torch-free frame-sampled video parity](../mage-vl-mlx-stage2-video-parity/README.md)(2026-08-25)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)

外部:

- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)(移植リポジトリ)
- [Microsoft Mage repository](https://github.com/microsoft/Mage/tree/main/mage_vl)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
