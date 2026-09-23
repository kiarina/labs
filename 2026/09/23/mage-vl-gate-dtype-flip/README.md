# Mage-VL の streaming gate は、どの dtype 構成で判定が反転するか

Mage-VL の MLX 移植シリーズの続編です(2026-09-23)。
[Stage 3](../../../08/25/mage-vl-mlx-stage3-streaming-gate/README.md) では、
`cut_event` の 1 時刻で float32 `0.5022` が bfloat16 `0.4977` になり、speak が silent へ
反転する例を 1 件見つけていました。その後の
[realtime lab](../../../08/27/mage-vl-realtime-benchmark/README.md) と Web UI は、
**model を bfloat16、gate を float32** にした構成を既定にしています。ただ、この構成で
反転が防げるかどうかは測っていませんでした。本 lab はそこを確かめます。

結論を先に書きます。

- **既定構成(bfloat16 vision + float32 gate)でも判定は反転します。** 閾値 0.5 では、
  codec 経路の 228 区間のうち 4 区間(異なる時刻としては 3 か所)で反転しました。
  すべて bfloat16 にした場合の 4 区間と変わりません
- 反転が起きたのは、float32 の `p_speak` が閾値から **0.023 以内**にある区間だけでした。
  閾値から ±0.025 より離れた区間では、どの構成でも反転していません
- ずれを生むのは gate だけではありません。gate の入力になる vision token を作る
  **vision tower の bfloat16 も、gate と同程度にずれを生みます**。float32 の判定を再現したいなら、
  vision tower と gate の両方を float32 にする必要があります

## 目的と問い

- 閾値付近の `p_speak` を持つ区間で、dtype の違いによる speak / silent の反転は
  どのくらいの頻度で起きるか
- 反転の原因は gate の bfloat16 か、gate へ入る vision token の bfloat16 か
- 既定構成(bfloat16 model + float32 gate)は、float32 の判定をどこまで再現するか
- 閾値からどれだけ離れていれば、反転しないとみなせるか

## 評価方法

1 つの区間を 1 回だけ前処理し、**同じ前処理結果**を次の 4 構成へ入れます。構成間で違うのは
演算精度だけです。

| 呼称 | vision tower | gate | 位置づけ |
|:---|:---|:---|:---|
| `f32/f32` | float32 | float32 | 基準。parity を確認した精度 |
| `bf16/bf16` | bfloat16 | bfloat16 | すべて bfloat16 |
| `bf16/f32` | bfloat16 | float32 | Web UI と `RealtimeSession` の既定 |
| `f32/bf16` | float32 | bfloat16 | 2x2 を埋めるための構成 |

- gate の読み方は公式 `inference_streaming.py` と移植の `scripts/gate_stream.py` に揃えました。
  動画を区間に分けて各区間の vision token を 1 本の因果 stream へ連結し、
  各区間の境界で `p_speak` を読みます
- 反転は、`f32/f32` と各構成とで `p_speak >= 閾値` の真偽が食い違った区間として数えます。
  閾値は公式既定の 0.5 と、Web UI の soccer goal preset が使う 0.3 の 2 つです
- 同じ構成で gate を 2 回通し、`p_speak` がビット単位で一致することを確かめました。
  反転が実行ごとの揺らぎではなく、dtype によるものだと言うためです

入力経路は 3 つです。

| 経路 | 内容 |
|:---|:---|
| `codec-source` | 区間を元のフレームレートのまま codec 前処理へ渡す(公式既定) |
| `codec-8fps` | 区間を 8 fps へ間引いてから codec 前処理へ渡す(Web UI と同じ) |
| `frames-2fps` | frames backend、2 fps・最大 16 frame(公式の frames 既定)。対照 |

区間長は 1 / 2 / 4 / 8 秒です。動画は次の 10 本です。

| 動画 | 出所 |
|:---|:---|
| `door_open`, `door_static`, `glass_fall`, `soccer_goal`, `soccer_idle`, `ltx2_dialogue` | 共有アセット `tests/assets/mp4/` |
| `pan_objects`, `street_ocr`, `faces_odd`, `cut_event` | 移植の `scripts/make_testdata.sh` で共有アセットの JPEG から決定的に生成(Stage 2 / 3 と同じ) |

### 実行環境

- MacBook Pro M1 Max、64 GB、macOS 26.6.2
- mlx 0.32.2、Docker 29.8.0(codec 前処理の container `mage-cvprep:0.2.5`)
- 移植: `kiarina/mage-vl-mlx` commit `355978b`
- 計測中は UnrealEditor などの GPU 負荷を落としています。ただし本 lab は時間ではなく数値を
  比べるので、負荷の影響は受けません

## 実行方法

```sh
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/kiarina/labs.git
cd labs
git sparse-checkout set .mise/tasks 2026/09/23/mage-vl-gate-dtype-flip
mise trust . && mise trust 2026/09/23/mage-vl-gate-dtype-flip
mise -C 2026/09/23/mage-vl-gate-dtype-flip run
```

`setup` が移植の clone、重みの変換、codec 前処理用 container の build、合成クリップの生成を
行います。変換済みの重みがあるときは `MAGE_VL_WEIGHTS` にその directory を指定すると、
変換を省略できます。結果は `output/gate-dtype.json` に出力され、`summarize.py` の集計が
標準出力へ出ます。M1 Max では全体で約 12 分でした(vision tower は bfloat16 で 181 秒、
float32 で 230 秒)。

## 観測した事実

区間の総数は 376 です(codec 2 経路で 236、frames で 140)。動画の末尾に残る 8 秒以降の
短い切れ端は、codec 前処理がグループを作れないため、公式と同じくスキップしました。
**同じ構成で 2 回通した gate の出力は、120 本の stream すべてでビット単位まで一致しました。**

### `p_speak` のずれの大きさ

基準 `f32/f32` との差です。

| 経路 | 構成 | 区間数 | 中央値 \|Δp\| | 最大 \|Δp\| | 中央値 \|Δlogit\| | 最大 \|Δlogit\| |
|:---|:---|---:|---:|---:|---:|---:|
| codec-source | bf16/bf16 | 119 | 0.0055 | 0.0812 | 0.034 | 0.461 |
| codec-source | bf16/f32 | 119 | 0.0048 | 0.0424 | 0.033 | 0.244 |
| codec-source | f32/bf16 | 119 | 0.0045 | 0.0322 | 0.029 | 0.197 |
| codec-8fps | bf16/bf16 | 117 | 0.0069 | 0.0510 | 0.054 | 0.252 |
| codec-8fps | bf16/f32 | 117 | 0.0057 | 0.0347 | 0.035 | 0.224 |
| codec-8fps | f32/bf16 | 117 | 0.0031 | 0.0384 | 0.026 | 0.260 |
| frames-2fps | bf16/bf16 | 140 | 0.0001 | 0.0211 | 0.075 | 0.414 |
| frames-2fps | bf16/f32 | 140 | 0.0001 | 0.0032 | 0.064 | 0.342 |
| frames-2fps | f32/bf16 | 140 | 0.0000 | 0.0070 | 0.036 | 0.149 |

codec の 2 経路には、同じ入力の重複を除いて 228 区間あります。この 228 区間で比べると、
`bf16/f32` の \|Δp\| が `bf16/bf16` より小さかったのは 138 区間でした。中央値は
0.0054 対 0.0058、95 パーセンタイルは 0.024 対 0.032 です。gate だけを float32 にした効果は
あるものの小さく、`f32/bf16`(vision だけ float32)の中央値 0.0036・95 パーセンタイル 0.021 と
同程度です。

### 反転

区間長が動画より長いと同じ区間が重複するので(`pan_objects` の 4 秒と 8 秒など)、
下の表では重複を除いて数えています。対象は codec の 228 区間です。

| 閾値 | 基準との距離 | 該当区間 | bf16/bf16 | bf16/f32 | f32/bf16 |
|---:|---:|---:|---:|---:|---:|
| 0.5 | ±0.01 以内 | 9 | 3 | 4 | 2 |
| 0.5 | ±0.025 以内 | 14 | 4 | 4 | 3 |
| 0.5 | ±0.05 以内 | 22 | 4 | 4 | 3 |
| 0.3 | ±0.01 以内 | 1 | 0 | 0 | 1 |
| 0.3 | ±0.025 以内 | 4 | 0 | 0 | 2 |
| 0.3 | ±0.05 以内 | 11 | 0 | 0 | 2 |

反転した区間は次のとおりです。

| 閾値 | 動画 | 経路 | 区間 | f32/f32 | bf16/bf16 | bf16/f32 | f32/bf16 |
|---:|:---|:---|:---|---:|---:|---:|---:|
| 0.5 | glass_fall | codec-source | 1 秒 #1 | 0.5224 | 0.5007 | 0.5086 | **0.4943** |
| 0.5 | glass_fall | codec-source | 1 秒 #3 | 0.4919 | **0.5119** | **0.5196** | **0.5021** |
| 0.5 | glass_fall | codec-source | 1 秒 #6 | 0.4975 | **0.5120** | **0.5399** | 0.4925 |
| 0.5 | glass_fall | codec-source | 2 秒 #3 | 0.4773 | **0.5085** | 0.4900 | 0.4856 |
| 0.5 | ltx2_dialogue | codec-source | 2 秒 #1 | 0.4983 | 0.4918 | 0.4987 | **0.5029** |
| 0.5 | ltx2_dialogue | codec-source | 4 秒 #0 | 0.5029 | **0.4994** | 0.5008 | 0.5010 |
| 0.5 | cut_event | codec-source / codec-8fps | 1 秒 #0 | 0.5022 | 0.5020 | **0.4897** | 0.5150 |
| 0.3 | door_static | codec-source | 1 秒 #7 | 0.2941 | 0.2878 | 0.2873 | **0.3028** |
| 0.3 | pan_objects | codec-8fps | 4 秒 #0 | 0.2895 | 0.2670 | 0.2750 | **0.3036** |

太字は基準と判定が食い違った値です。`cut_event` の 1 秒 #0 は黒画面だけの区間で、
2 つの codec 経路が同じ値を返しました。上の件数の表では経路ごとに 1 件と数えているので、
`bf16/f32` の 0.5 での 4 件は、異なる時刻としては 3 件です。

frames 経路は 140 区間すべてで `p_speak` が閾値から遠く(Stage 3 以降の記録どおり)、
反転は 0 件でした。

## 解釈

- **既定構成の `bf16/f32` は、float32 の判定を再現しません。** gate を float32 に上げても、
  gate へ入る vision token がすでに bfloat16 の丸めを含んでいます。この計測では、
  vision tower 由来のずれ(`bf16/f32`)と gate 由来のずれ(`f32/bf16`)は同じ桁でした
- 2 つのずれは足し算になりません。`bf16/bf16` と `bf16/f32` で反転した区間は一部しか
  重なっておらず、`bf16/bf16` のほうが基準に近い区間もあります(`cut_event` 1 秒 #0)。
  「片方だけ float32 にすれば半分安全」とは言えません
- 反転が起きた区間は、基準の `p_speak` が閾値から 0.023 以内のものだけでした。
  ±0.01 以内の 9 区間では 2〜4 区間、つまり 2〜4 割が反転しています。閾値に十分近い区間では、
  bfloat16 を含む構成の判定はほぼ当てにならないと考えるのが安全です
- 閾値付近の区間は珍しくありません。codec 経路の 228 区間のうち、22 区間(約 1 割)が
  0.5 の ±0.05 以内にありました。長時間の運用では反転が繰り返し起きると考えてください
- Web UI での gate の使い方は、低い閾値で生成を省く pre-filter です
  (realtime lab の結論)。この用途なら、境界の区間で生成するかどうかが入れ替わるだけで、
  最終的な判定は生成文が決めます。したがって実運用への影響は小さいと考えます。
  **影響が大きいのは、判定の再現性そのものが要る場面**です(移植の検証、他環境との比較、
  記録の再現)。この場合は、公式 `inference_streaming.py` の既定どおり全体を float32 で
  動かしてください

## 成立範囲と未確認の事項

- 動画は 10 本、しかも 7〜8 秒以下の短いものだけです。反転の割合は、閾値付近にどれだけの
  区間が集まるかに左右されるため、他の動画での件数へそのまま外挿しないでください
- 閾値からの「安全距離」0.023 は、この 228 区間で観測した最大値です。上限を保証する値では
  ありません。\|Δp\| の最大は `bf16/bf16` で 0.081 あったため、閾値から 0.023 より離れていれば
  反転しない、とは言い切れません
- gate の読み方は、動画全体を 1 本の stream にする offline 構成です。Web UI の
  `RealtimeSession` は、context window で履歴を区切ります。区切り方が違えば個々の値は
  変わりますが、dtype によるずれの大きさの傾向は変わらないと推測しています(未確認)
- M1 Max の 1 台だけで測りました。MLX の bfloat16 の演算経路は同じ世代の Apple Silicon で
  共通だと考えていますが、M4 Max での値の一致は確かめていません
- 量子化(8 bit / 4 bit)の影響は、本 lab の範囲外です
