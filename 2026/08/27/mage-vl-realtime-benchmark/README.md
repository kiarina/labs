# Mage-VL のリアルタイム区間処理は入力に追いつけるか

Mage-VL の MLX 移植シリーズの続編です。前段で 4 経路の float32 parity と
streaming gate の機能を確認しましたが、既存の `inference_streaming.py` は動画全体を
先に処理する offline 構成でした。本 lab は、区間が到着するたびに処理する実装で、
Apple Silicon 上の応答遅延と backlog を測ります(2026-08-27)。

実装本体とローカル Web UI は
[`kiarina/mage-vl-mlx`](https://github.com/kiarina/mage-vl-mlx)に置き、
この lab には評価条件、runner、raw output、集計、解釈だけを置きます。

## 目的と問い

- segment 終端から最初の生成文字と全文まで、何秒かかるか
- 1 / 2 / 4 / 8 秒の segment で処理時間は segment 間隔以内に収まり、継続入力へ追いつけるか
- 遅延の内訳は、subclip 準備、前処理、vision tower、gate、生成のどこにあるか
- frames と codec、bfloat16 model + float32 gate の構成で結果はどう変わるか
- 実況、見守り、イベント要約など、どの程度のリアルタイム用途に使えそうか

## 「リアルタイム」の定義

本 lab では、次の 2 条件を分けます。

1. **sustained throughput**: 各 segment の処理が次の segment 到着までに終わり、
   継続入力で処理待ちが増えない
2. **response latency**: segment が確定してから first text / 全文が表示されるまでの時間が、
   対象用途で許容できる

1 を満たしても、4 秒 segment なら入力の確定自体に最大 4 秒待ちます。したがって、
モデル処理だけを「リアルタイム」と呼ばず、segment 待ちと処理後の遅延を分けて報告します。

## 評価方法

- 移植: `kiarina/mage-vl-mlx` commit
  `2948a53f677b36c7201bbe0246ddaf17a4edfe9d`

  `mise run setup` の既定は、カメラ計測にも使える `6b1438e` を取得します。上の表を
  そのまま追試する場合は `PORT_COMMIT=2948a53 mise run` を使ってください。二つの commit
  の間で `run_matrix.py` が呼ぶ経路の変更は、codec の binary 検出とエラーメッセージだけです
- model: bfloat16
- streaming gate: float32
- gate threshold: `0`(すべての segment で生成し、worst-case の負荷を見る)
- prompt: `Describe what is happening. Focus on changes and motion.`
- generation: greedy、16 token
- video: `glass_fall_768x512_24fps_8s_490kb.mp4`
- segment: 1 / 2 / 4 / 8 秒
- 各条件 3 回。中央値を使用する
- frames: segment あたり最大 16 frame、2 fps
- codec: 公式 `codec-video-prep` 0.2.5 を ARM64 Linux container で実行

動画は LTX-2 で生成した共有アセットです。生成条件と event の目視時刻は
[`mage-vl-streaming-event-detection`](../../25/mage-vl-streaming-event-detection/README.md)に
記録されています。追試では再生成せず、固定アセットを使用します。

測定する時刻。

- subclip の re-encode
- frames / codec 前処理
- gate 用 vision tower
- 累積 visual history に対する streaming gate
- segment 終端から first token まで
- segment 終端から生成完了まで
- real-time factor、次の segment 到着時点の backlog、peak memory

gate は公式の whole-stream 結果を保つため、新しい segment ごとに累積 visual history を
再評価します。Mamba state の incremental cache は未実装です。この再計算コスト自体を
長い stream の制約として測ります。

## 実行方法

Apple Silicon Mac、[mise](https://mise.jdx.dev/)、uv、FFmpeg、Git が必要です。
初回は Mage-VL checkpoint の取得と MLX 形式への変換を行います。

```sh
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/kiarina/labs.git
cd labs
git sparse-checkout set .gitignore .mise/tasks Makefile mise.toml \
  2026/08/27/mage-vl-realtime-benchmark
mise -C 2026/08/27/mage-vl-realtime-benchmark run
```

codec 条件は Docker も必要です。

```sh
mise -C 2026/08/27/mage-vl-realtime-benchmark run codec
```

`run_matrix.py` は `--model-dtype` と `--gate-dtype` を受け取り、run 1 を cold、
run 2 以降を warm として分けて集計します。

すでに変換済みの重みがある場合だけ、`MAGE_VL_WEIGHTS` にその directory を指定できます。

長時間セッションの memory を測るときは、固定した checkout から Web UI を起動しておき、
別の shell で sampler を回します。区切りごとに `output/{host}-marks.txt` へラベルを
追記すると、次の sample にそのラベルが付きます。

```sh
mise -C 2026/08/27/mage-vl-realtime-benchmark run memory
```

## 現在の結果

Mac Studio (Apple M4 Max、128 GB、macOS 26.5.2) で測定しました。
以下は frames / codec backend・16 token、各条件 3 回の中央値です。

| backend | segment | RTF | first text | full response | 最大 backlog | 区間内に完了 | peak memory |
|:---|---:|---:|---:|---:|---:|:---:|---:|
| frames | 1 秒 | 1.190 | 1.605 秒 | 1.741 秒 | 1.224 秒 | no | 11.96 GB |
| frames | 2 秒 | 1.140 | 2.579 秒 | 2.669 秒 | 0.765 秒 | no | 12.01 GB |
| frames | 4 秒 | 1.193 | 4.819 秒 | 5.224 秒 | 0.811 秒 | no | 12.74 GB |
| frames | 8 秒 | 1.250 | 9.606 秒 | 10.053 秒 | 0 秒\* | no | 14.27 GB |
| codec | 1 秒 | 1.510 | 3.677 秒 | 3.940 秒 | 3.675 秒 | no | 11.98 GB |
| codec | 2 秒 | 1.394 | 3.351 秒 | 3.700 秒 | 2.188 秒 | no | 12.23 GB |
| codec | 4 秒 | 0.898 | 3.277 秒 | 3.612 秒 | 0 秒 | **yes** | 12.38 GB |
| codec | 8 秒 | 0.744 | 5.615 秒 | 5.981 秒 | 0 秒\* | **yes** | 13.08 GB |

\* 8 秒条件は有効区間が 1 本だけなので、次区間到着時の backlog は観測できません。
frames の処理時間は 8 秒を超えており、継続入力なら遅延が蓄積します。

frames はすべての条件で sustained throughput を満たしませんでした。1 秒条件なら最初の
文字は区間確定から約 1.60 秒後に出ますが、処理待ちは継続的に増えます。2 秒条件が RTF
では最良の 1.140 で、短くしても固定費、長くしても frame と累積 prompt の増加が効きました。

codec は 4 秒以上で継続入力に追いつき、4 秒条件では区間確定から first text 3.277 秒、
全文 3.612 秒でした。今回の条件ではこれが throughput と応答速度の最良の折衷です。
ただし event 発生からは segment 確定待ちもあるため、最悪では first text まで約 7.3 秒です。
1 / 2 秒条件は codec 前処理の固定費と backlog が大きく、短くすれば低遅延になるとは
限りません。現状は即時の実況より、数秒の遅延を許容するイベント要約・見守り通知向けです。

遅延の主因は生成です。4 秒条件の中央値は subclip 0.150 秒、前処理 0.087 秒、
vision 0.841 秒、gate 0.023 秒、生成 3.690 秒でした。codec・4 秒では前処理
0.650 秒、vision 0.417 秒、gate 0.054 秒、生成 2.320 秒です。codec 前処理は増えますが、
visual token を疎にした後の vision と生成が短く、全体では frames を上回りました。
次は threshold 0 の worst-case だけでなく、gate で生成を抑制した実運用寄りの負荷も
別途評価します。

最初の試行では、MP4 container の duration が `8.041667` 秒だったため、4 秒区間 2 本に
加えて末尾 `0.041667` 秒を 1 区間として処理しました。この端数は独立した観測として意味がなく、
backlog の集計も歪めました。そこで 0.5 秒未満の末尾端数を除外する条件を事前に追加し、
移植 commit を更新しました。上記の 4 秒条件は修正後の 2 区間だけを使います。

## 解釈の基準

- real-time factor が 1 未満でも、first text が用途上遅ければ「リアルタイムに使える」とはしない
- 短い segment ほど event の時刻は絞れるが、prompt 処理と生成の頻度が増える
- threshold 0 は worst-case。実運用では gate で生成を減らせるが、frames backend の gate は
  codec と異なる挙動をするため、単純な負荷削減値として一般化しない
- codec は入力 coverage を保ちやすい一方、container 起動と前処理が live latency に加わる

## MacBook Pro M1 Max の固定動画 matrix

同じ動画・同じ条件を MacBook Pro (Apple M1 Max、64 GB、macOS 26.5.2) でも測り、
機種差を分離しました(2026-08-27)。移植は commit `6b1438e`、それ以外の条件は上の
Mac Studio の matrix と同一です。

| backend | segment | RTF 中央値 | RTF 範囲 | first text | full response | 最大 backlog | 区間内に完了 | peak memory |
|:---|---:|---:|---:|---:|---:|---:|:---:|---:|
| frames | 1 秒 | 2.225 | 2.222-4.319 | 8.484 秒 | 8.777 秒 | 8.474 秒 | no | 11.96 GB |
| frames | 2 秒 | 1.991 | 1.988-2.001 | 6.766 秒 | 6.936 秒 | 5.851 秒 | no | 12.01 GB |
| frames | 4 秒 | 2.103 | 2.102-2.109 | 10.126 秒 | 10.705 秒 | 4.469 秒 | no | 12.74 GB |
| frames | 8 秒 | 2.313 | 2.311-2.319 | 17.944 秒 | 18.597 秒 | 0 秒\* | no | 14.27 GB |
| codec | 1 秒 | 2.518 | 2.510-2.727 | 8.127 秒 | 8.536 秒 | 10.811 秒 | no | 11.98 GB |
| codec | 2 秒 | 2.594 | 2.594-2.600 | 8.863 秒 | 9.437 秒 | 9.118 秒 | no | 12.23 GB |
| codec | 4 秒 | **1.648** | 1.641-1.661 | 7.700 秒 | 8.260 秒 | 3.292 秒 | no | 12.38 GB |
| codec | 8 秒 | **1.425** | 1.407-1.428 | 10.843 秒 | 11.459 秒 | 0 秒\* | no | 13.08 GB |

\* 8 秒条件は有効区間が 1 本だけなので、次区間到着時の backlog は観測できません。

この matrix では、M1 Max はどの条件でも継続入力に追いつきませんでした。最良でも
codec・8 秒の RTF `1.425` です。両機の RTF 比は全 8 条件で 1.67〜1.92 倍に収まっており、
機種差は条件によらずほぼ一定でした。

**ただしこの結果は、ファイル経路が codec へ元のフレームレートのまま渡していたことに
起因します。**下記「ファイル経路のフレームレート」で測り直すと、M1 Max でも RTF は
`0.808` になります。上の表は、その修正前の記録として残しています。

codec の効き方自体は M1 Max でも同じ方向です。8 秒条件で frames `2.313` に対し
codec `1.425` と 4 割速く、短い segment では codec 前処理の固定費が上回る点も同じでした。
peak memory は Mac Studio と同一条件で 11.96〜14.27 GB / 11.98〜13.08 GB と一致しており、
同じ形状の計算をしていることの裏取りになっています。

### ファイル経路のフレームレート

カメラ経路はブラウザが capture rate で間引いた frame を送りますが、`extract_subclip` は
**元の動画のフレームレートのまま**区間を切り出していました。24 fps の動画では 4 秒の window が
96 frame になり、32 frame までは canvas 4 枚で済むという境界を大きく超えます。

| 経路 | window の frame 数 | canvas 数 | visual token | cv-preinfer |
|:---|---:|---:|---:|---:|
| ファイル(24 fps のまま) | 96 | 16 | 2,016 | 1.43 秒 |
| カメラ(8 fps) | 32 | 4 | 576 | 0.72 秒 |
| ファイルを 8 fps で切り出し | 34 | 4 | 504 | 0.73 秒 |

`extract_subclip` に `-r` を足して capture rate で切り出すよう変更し、codec matrix を
測り直しました(移植 commit `7aa0324`、`--resample-codec-input`)。

| segment | RTF(24 fps) | RTF(8 fps) | first text | full response | 区間内に完了 |
|---:|---:|---:|---:|---:|:---:|
| 1 秒 | 2.518 | 3.314 | 11.531 秒 | 12.158 秒 | no |
| 2 秒 | 2.594 | **1.730** | 5.215 秒 | 5.808 秒 | no |
| **4 秒** | 1.648 | **0.808** | **2.680 秒** | **3.219 秒** | **yes** |
| **8 秒** | 1.425 | **0.816** | 5.830 秒 | 6.560 秒 | **yes** |

**M1 Max でも 4 秒以上なら継続入力に追いつきます。** 4 秒条件の first text は
`7.700` 秒から `2.680` 秒へ 2.9 倍改善しました。段の内訳では vision が 1.06 → 0.31 秒、
生成が 6.22 → 1.97 秒です。

1 秒条件だけは悪化しました(`2.518` -> `3.314`)。1 秒 × 8 fps = 8 frame は codec の下限
ちょうどで、canvas 数はもともと 4 枚だったため削減効果が無く、区間が短いぶん前処理の
固定費 0.65 秒が相対的に重くなるためです。**間引きは常に得ではなく、区間長との
組み合わせで決まります。**

この修正は Mac Studio の matrix には未適用です。上の M4 Max の表も 24 fps のままの記録であり、
同様に改善する可能性がありますが未測定です。

### cold start は「マシンにつき 1 回」で、プロセスごとではない

frames・1 秒条件の run 1 だけ RTF `4.319` と突出しました。内訳を見ると、原因は
最初の 1 segment だけです。

| | segment 1 | segment 2 | segment 3 | segment 8 |
|:---|---:|---:|---:|---:|
| run 1 | **19.21 秒** | 2.24 秒 | 2.06 秒 | 2.42 秒 |
| run 2 | 2.41 秒 | 2.21 秒 | 2.06 秒 | 2.41 秒 |
| run 3 | 2.39 秒 | 2.23 秒 | 2.06 秒 | 2.42 秒 |

一度きりの上乗せは約 16.8 秒でした。ところが 2 / 4 / 8 秒条件は別プロセスで起動している
にもかかわらず、同じ上乗せが出ていません。あとから同じ 1 秒条件を新しいプロセスで
測り直すと、segment 1 は `2.47` 秒、`model_load_s` は `0.72` 秒でした。

つまりこの cold cost はプロセスの初期化ではなく、8.8 GB の重みが最初に page-in される
コストで、以降は OS の page cache が効きます。**cold start はマシンで最初の 1 回だけ
現れる**と読むべきで、プロセス起動のたびに払う固定費として一般化できません。
`model_load_s` 自体は初回 `1.23` 秒、以降 `0.74` 秒で、いずれも支配的ではありません。

### dtype 構成の比較

gate の再現性を優先する float32、実運用速度を優先する bfloat16、その混合を、
M1 Max・4 秒 segment・3 回の中央値で比べました。

| model / gate dtype | backend | RTF | first text | full response | vision | gate | 生成 | peak memory |
|:---|:---|---:|---:|---:|---:|---:|---:|---:|
| bfloat16 / float32 (既定) | frames | 2.103 | 10.126 秒 | 10.705 秒 | 1.441 秒 | 0.097 秒 | 6.523 秒 | 12.74 GB |
| bfloat16 / bfloat16 | frames | 2.098 | 10.315 秒 | 10.882 秒 | 1.439 秒 | 0.065 秒 | 6.523 秒 | 11.70 GB |
| float32 / float32 | frames | 2.894 | 16.261 秒 | 17.436 秒 | 1.447 秒 | 0.079 秒 | 9.553 秒 | 23.39 GB |
| bfloat16 / float32 (既定) | codec | 1.648 | 7.700 秒 | 8.260 秒 | 0.766 秒 | 0.045 秒 | 4.448 秒 | 12.38 GB |
| bfloat16 / bfloat16 | codec | 1.636 | 7.589 秒 | 8.151 秒 | 0.768 秒 | 0.025 秒 | 4.442 秒 | 11.36 GB |
| float32 / float32 | codec | 2.547 | 12.117 秒 | 13.732 秒 | 1.002 秒 | 0.079 秒 | 7.480 秒 | 22.71 GB |

**gate を float32 に上げる代償はほとんどありません。** bfloat16 gate との差は RTF で
0.2〜0.7%、peak memory で約 1 GB です。gate は 1 segment あたり 0.03〜0.10 秒しか
使っていないため、精度を上げても全体には響きません。

一方 **model 全体を float32 にすると 1.4〜1.5 倍遅くなり、peak memory は約 1.8 倍**に
なります (12.7 GB -> 23.4 GB)。得られるのは parity の再現性だけで、実運用の速度には
不利です。したがって既定の bfloat16 model + float32 gate が、この 3 択では妥当でした。

参考として、この動画での gate の p(speak) は次の通りでした。

| backend | bfloat16 gate | float32 gate (既定) | float32 model + gate |
|:---|:---|:---|:---|
| codec | 0.6702, 0.5432 | 0.6779, 0.5623 | 0.6865, 0.5698 |
| frames | 0.0009, 0.0060 | 0.0009, 0.0062 | 0.0010, 0.0064 |

この 2 segment では、どの構成でも閾値をまたぐ判定の反転は起きていません。dtype による
反転は閾値の近くでのみ問題になるという既存の結論と矛盾しませんが、この動画は
閾値付近の値を持たないため、反転の有無を検証できる材料ではありません。

### 用途別に見た許容遅延

event が起きてから全文が出るまでの最悪遅延は、`segment 長 + full response` です
(event が segment の先頭で起きた場合)。

| 機種 | backend | segment | RTF | 最悪の event -> 全文 |
|:---|:---|---:|---:|---:|
| M4 Max | frames | 1 秒 | 1.190 | 2.74 秒 |
| M4 Max | frames | 2 秒 | 1.140 | 4.67 秒 |
| M4 Max | codec | 4 秒 | **0.898** | 7.61 秒 |
| M1 Max | frames | 2 秒 | 1.991 | 8.94 秒 |
| M1 Max | codec | 4 秒 | 1.648 | 12.26 秒 |
| M4 Max | codec | 8 秒 | **0.744** | 13.98 秒 |
| M1 Max | codec | 8 秒 | 1.425 | 19.46 秒 |

RTF が 1 未満でなければ、この遅延は初期値であって時間とともに増え続けます。上の表で
継続入力に耐えるのは M4 Max の codec・4 秒と 8 秒だけです。

- **実況・対話補助** (1〜2 秒): 今回の構成ではどの機種でも成立しません。M4 Max の
  frames・1 秒は遅延 2.74 秒と近いものの RTF `1.190` で追いつけず、backlog が増え続けます
- **イベント要約・見守り通知** (5〜15 秒): M4 Max の codec・4 秒が唯一、遅延 7.61 秒で
  かつ継続入力に耐えます。現時点で推奨できる唯一の実運用構成です
- **事後の要約・タグ付け** (リアルタイム性不要): M1 Max でも実用になります。RTF 1.4〜2.3 は
  「8 秒の動画に 11〜19 秒かかる」という意味で、バッチ処理としては十分です

M1 Max でリアルタイム側に寄せるには、segment をさらに伸ばす、生成 token を減らす、
量子化する、のいずれかが要ります。今回の測定範囲では未検証です。

## MacBook Pro M1 Max の実カメラ継続運用

Mac Studio の matrix は動画ファイルを固定入力にしていますが、実際のカメラ入力と
長時間プロセスの挙動は別の問いです。MacBook Pro (Apple M1 Max、64 GB、macOS 26.5.2) の
内蔵 FaceTime HD カメラで、Web UI をそのまま連続運用して測りました(2026-08-27)。

- 移植: `kiarina/mage-vl-mlx` commit `d4ad9e1`
- 入力: ブラウザが camera stream を最大幅 768 px の JPEG へ縮小して送信する
- model bfloat16 / gate float32、gate threshold `0`、Event filter mode
- 軽い設定: stride 1 秒、window 4 秒、2 fps、最大 16 frame、2 token
- 重い設定: stride 8 秒、window 16 秒、4 fps、最大 64 frame、32 token
- 計測: `sample_memory.py` が UI の `/api/memory` と macOS の `footprint` を同一時点で読む

### 応答速度: 1 秒 stride には追いつけない

軽い設定を 5 分続けたときの、53 segment の中央値です。

| 段階 | 中央値 |
|:---|---:|
| frame の mp4 化 | 0.020 秒 |
| frames 前処理 | 0.067 秒 |
| vision tower | 1.814 秒 |
| streaming gate | 0.159 秒 |
| 生成 prefill (first token まで) | 7.335 秒 |
| 生成完了 (2 token) | 7.457 秒 |
| **1 segment 合計** | **9.484 秒** (最小 8.017、最大 11.174) |

stride 1 秒に対して 1 segment 9.5 秒なので real-time factor は約 9.5 です。2 token しか
生成していないのに生成が 7.5 秒を占めており、律速は decode ではなく visual token に対する
prefill でした。Mac Studio M4 Max の同条件 (vision 0.841 秒、first text 4.819 秒) と比べると、
M1 Max はおよそ 1.8 倍遅く、M4 Max で見つけた codec・4 秒の折衷はそのままでは移りません。

### メモリ: MLX peak は必要量の指標にならない

各時点で、UI process の MLX allocator と macOS の `footprint` を同時に読みました。

| 時点 | MLX active | MLX cache | MLX peak | footprint | swap 使用 |
|:---|---:|---:|---:|---:|---:|
| model load 直後 | 12.02 GB | 1.05 GB | 12.01 GB | 15 GB | 0 |
| 軽い設定 +1 分 | 11.70 GB | 9.74 GB | 12.465 GB | 22 GB | 0 |
| 軽い設定 +5 分 | 10.91 GB | 10.53 GB | 12.465 GB | 22 GB | 0 |
| Stop 後 +45 秒 | 10.83 GB | 10.61 GB | 12.465 GB | 22 GB | 0 |
| 同一プロセスの 2 回目 run | 11.68 GB | 9.77 GB | 12.465 GB | 22 GB | 0 |
| 重い設定 +3 分 | 16.83 GB | 27.30 GB | 16.91 GB | 45 GB | 8.6 GB |
| 重い設定 Stop 時 | 14.74 GB | 34.51 GB | 22.04 GB | 49 GB | 17.2 GB |
| 重い設定 Stop +60 秒 | 10.83 GB | 38.41 GB | 22.04 GB | 50 GB | 12.6 GB |

観測できた事実は次の通りです。

- `footprint` の `IOAccelerator (graphics)` は、全条件で MLX の active + cache とほぼ一致した。
  footprint が MLX peak より大きいのは Metal の予約分ではなく、MLX 自身の buffer cache である
- 同じ設定を続ける限り増えない。5 分の連続運用でも、同一プロセスの 2 回目 run でも、
  MLX peak は `12.465` GB から動かず footprint も 22 GB のままだった
- 一度でも重い設定を実行すると cache がその高水位まで伸び、**Stop してもアイドルでも返らない**。
  停止して 60 秒経っても cache 38.41 GB、footprint 50 GB を保持し続けた
- 64 GB の機体でも、重い設定では swap が 17.2 GB まで増えた。MLX peak は同時点で 22.04 GB
  であり、**MLX peak を必要 unified memory の見積もりに使うと危険である**
- `mx.clear_cache()` は有効だった。プロセスの再起動は不要である

  | 呼び出し時点 | 解放量 | 呼び出し後の footprint |
  |:---|---:|---:|
  | 重い設定で稼働中 | 34.25 GB | 50 GB -> 16 GB |
  | 重い設定を Stop した直後のアイドル | 34.06 GB | 46 GB -> **12 GB** |

  ただし稼働中に解放しても、同じ設定を続ける限り working set は再確保されます。実測では
  150 秒後に cache 28.68 GB、footprint 46 GB へ戻りました。解放が意味を持つのは、
  重い設定から軽い設定へ移るときと、run を止めたときです。停止後に解放すると、
  アイドルのプロセスはモデル重みぶんの 12 GB まで落ちます

したがって必要メモリは、短時間の MLX peak ではなく、**実際に使う最大設定での footprint**
で見積もるべきです。長時間運用では、run の終了時に cache を解放する必要があります。
この結果を受けて、`mage-vl-mlx` の Web UI は run が停止したときに `mx.clear_cache()` を
呼ぶようにしました。

`RSS` はこの用途では指標になりません。重い設定に移ると、モデルの常駐分が GPU 側の
確保へ移るため RSS は 10.9 GB から 0.45 GB へ落ち、実使用量とは逆方向に動きました。

### カメラ経路で確認できたこと

- Chrome では permission dialog を許可すると preview が出て、`enumerateDevices` の
  device 名 (`FaceTime HDカメラ`) が表示された。Stop 後の再開と、UI を reload してからの
  再有効化では、再度の許可を求められない
- permission を拒否された場合、UI は `Permission denied` を表示して停止し、
  console error を出さない。Claude の in-app browser は capture を禁止しているため、
  この経路の確認に使えた
- 5 分の連続運用と、同一プロセスでの 2 回目 run は、いずれもエラーなく完了した

### カメラモードで見つかった 2 つの表示上の問題

処理が入力に追いつかない条件では、UI の表示が実態とずれます。どちらも計測ではなく
表示側の定義の問題です。

- `STREAM LAG` は frame queue の長さから計算していたため、queue の上限
  (`max(16, fps * stride * 4)`) で頭打ちになり、実際には 66 秒遅れている状況でも
  `8.00s` を表示し続けた
- segment の時刻は処理した segment 数から数えていたため、drop された frame の分だけ
  実時刻から乖離した。実測では 6 分間の運用で表示上の stream 時刻が 53 秒までしか進まなかった。
  内容は最新 frame なので live に近いが、ラベルが誤解を招く

## カメラ入力で streaming gate は使えるか

Web UI のカメラモードは frames backend 固定で、そこでは gate の確率が `0.001` 前後に
張り付き、実質的に使えませんでした。Mage-VL の看板機能である proactive streaming を
ライブカメラで一切実演できない状態だったので、原因と可否を調べました(2026-08-27)。

### 原因は codec ではなく、書き出しコーデックの選択だった

カメラ経路には圧縮動画が存在しません。ブラウザは canvas から独立した JPEG 静止画を送り、
サーバが `cv2.VideoWriter` の `mp4v`(MPEG-4 Part 2)で mp4 に再エンコードしていました。
公式 `cv-preinfer` はこのビットストリームを解析できず、`KeyError: 'pixels'` で落ちます。

同じ 8 フレームのカメラ相当クリップを、コーデックだけ変えて公式実装に通しました。

| コーデック | 結果 | 所要 |
|:---|:---|---:|
| MPEG-4 Part 2 | 失敗 `KeyError: 'pixels'` | — |
| H.264 | 成功 | 0.70 秒 |
| HEVC | 成功 | 0.69 秒 |
| VP9(webm / mp4) | 失敗 `KeyError: 'pixels'` | — |

bitcost リーダーが解析できるのは H.264 / HEVC 系のブロック構造だけ、と読めます。

フレーム数には下限があります。`cv-preinfer` は `--min_group_frames 8` で実行しているため、
**1 window あたり 8 フレーム以上**が必要で、4 フレームでは
`RuntimeError: no canvases produced` になります。ライブ入力では
`window 秒数 × capture fps` がこれを満たす必要があり、たとえば window 2 秒・2 fps では
足りません。

### 2-8 fps の静止画を再エンコードしても gate 信号は残る

codec-native は圧縮ストリームから bit cost を読みます。それを 2-8 fps の静止画から
作り直したとき、信号が残るのか、元の 24 fps エンコードの性質だったのかを分けました。
カメラ経路を完全に再現し(デコード、UI と同じ 768 px 幅へ縮小、JPEG 品質 84、再エンコード)、
同じクリップのネイティブ経路と比べています(`camera_codec_probe.py`)。

| 経路 | `door_static` 0-4 | 4-8 | `soccer_goal` 0-4 | 4-8 |
|:---|---:|---:|---:|---:|
| ネイティブ file / frames | 0.0039 | 0.0029 | 0.0010 | 0.0004 |
| ネイティブ file / codec | 0.0781 | 0.0861 | 0.7994 | 0.6924 |
| カメラ相当 2 fps H.264 / codec | 0.1439 | 0.1205 | **0.7907** | **0.8184** |
| カメラ相当 4 fps H.264 / codec | 0.1885 | 0.2677 | **0.9110** | **0.8956** |
| カメラ相当 8 fps H.264 / codec | 0.1296 | 0.0715 | **0.7181** | **0.8247** |
| カメラ相当 2-8 fps / frames | 0.0005-0.0129 | | 0.0001-0.0015 | |
| カメラ相当 mp4v / codec | 失敗 | 失敗 | 失敗 | 失敗 |

**gate はカメラ経路でも content type を判別しました。** 2 fps の静止画を再エンコードした
だけでも、スポーツ 0.79-0.82 と静止シーン 0.12-0.14 が分かれます。閾値 0.3-0.5 なら
どの capture rate でも判別できます。frames 経路は最大 `0.0129` なので、どんな閾値でも
機能しません。

capture rate は高いほど良いわけではありませんでした。4 fps はスポーツ側が最も高くなる
一方で静止シーンも `0.2677` まで上がり、判別の余裕は最も狭くなります。

### 実カメラでの効果

`camera_clip` を H.264 で書き出すよう変更し、カメラモードの codec 制限を外して、
MacBook Pro M1 Max の内蔵カメラで 21 区間を実測しました(4 秒 stride、16 token)。

| 指標 | frames(変更前) | codec(変更後) |
|:---|---:|---:|
| 1 区間の処理 | 約 8.5 秒 | **2.488 秒**(中央値) |
| real-time factor | 約 2.1 | **約 0.62** |
| vision tower | 1.8 秒 | 0.35 秒 |
| codec 前処理 | — | 0.65 秒 |
| 生成 | 6.5 秒 | 1.44 秒 |
| 遅延 | 増え続ける | 2.66 秒 -> 2.67 秒で安定 |
| gate `p_speak` | 0.001 前後 | 0.088-0.692 |

**M1 Max のライブカメラが継続入力に追いつきました。** 生成が 6.5 秒から 1.44 秒に落ちたのは
visual token が減ったためで、カメラ相当ウィンドウでの実測は frames 2,688 に対し codec 576
(79% 削減)でした。M1 Max で律速だった prefill に直接効いています。

### canvas 数はフレーム数に段階的にしか反応しない

capture rate を上げると何が増えるのかを、カメラ相当クリップで測りました。

| window のフレーム数 | canvas 数 | visual token | cv-preinfer |
|---:|---:|---:|---:|
| 8(2 fps × 4 秒) | 4 | 576 | 0.66 秒 |
| 16(4 fps × 4 秒) | 4 | 576 | 0.64 秒 |
| **32(8 fps × 4 秒)** | **4** | **576** | 0.72 秒 |
| 64(16 fps × 4 秒) | 12 | 1,728 | 0.92 秒 |
| 120(30 fps × 4 秒) | 20 | 2,880 | 1.21 秒 |

`--group_size 32` でフレームをまとめ、グループごとに `--images_per_group 4` 枚の canvas を
作る設定なので、**32 フレームまでは 1 グループ = canvas 4 枚で一定**です。モデルが受け取る
visual token も 576 で変わりません。

つまり 2 fps から 8 fps への引き上げは、**モデルの負荷を増やさずに codec の時間解像度だけを
4 倍にします**。増えるのは前処理の 0.06 秒だけです。32 フレームを超えると canvas が増え、
120 フレームでは vision が 0.35 → 1.21 秒、生成が 1.44 → 6.81 秒、1 区間あたり約 3.8 倍に
なりました。運用上は **`window 秒数 × capture rate` を 32 に寄せる**のが最適です。

なおブラウザ側は 1 フレームごとに JavaScript で JPEG を作るため、高いレートには追随できません。
30 fps を要求して実測 10.6 fps でした。要求どおり書き出すと動画が実時間より速くなるため、
実測レートで書くよう修正しています。

### 質問内のラベルの並び順は、時間解像度より効くことがある

ジェスチャ検出で `hand-out`(手が消える)が検出されない問題がありました。capture rate を
2 fps から 8 fps へ上げると検出されるようになりましたが、**質問文の中で `hand-out` の説明を
`hand-in` より前に移すと、2 fps でも検出できるようになりました**。

観測できたのはこの 1 例だけであり、モデルが並び順のどこに反応しているかは分かりません。
ただし実務上は、**あるラベルが取れないときは、フレーム数を増やす前に説明の順序を試す**ほうが
安く効く場合がある、と言えます。ラベル定義の書き方そのものが検出性能の一部です。

### 副作用として見つけた運用上の問題

`run_cv_preinfer` は動画のパスごとに codec アセットをキャッシュし、削除しません。
1 アセット約 574 KB なので、1 秒 stride のライブカメラでは **1 時間あたり約 2 GB** 増えます。
ライブ経路ではキャッシュを使い捨てにする必要があり、`RealtimeSession` に
`codec_cache_root` と `codec_cache_ephemeral` を追加しました。21 区間を流したあとも
共有キャッシュは 107 個のまま増えず、一時ディレクトリも残らないことを確認しています。

### この結果の範囲

- 実カメラの測定は M1 Max の 1 セッション、21 区間のみで、中央値のばらつきは取っていない
- gate の判別はスポーツと静止シーンの 2 種類でしか確認していない
- 再エンコードした bit cost は、カメラ本来の圧縮ではなく我々のエンコーダの出力である。
  ブラウザの `MediaRecorder` で本物の圧縮ストリームを送る構成は見送った。削れるのは
  再エンコードの 0.09 秒だけで、現行方式でも 32 フレームまではモデルの負荷を増やさずに
  時間解像度を上げられるため
- ラベルの並び順の効果は 1 例の観測であり、他のラベルや他の質問でも成り立つかは未確認
- capture rate の効果は `hand-out` 1 ラベルでの観察で、系統的な precision / recall は未測定

## Web UI のサッカー goal preset の校正

`mage-vl-mlx` の Web UI には、用途特化 event filter の実例として goal preset があります。
出荷時の gate threshold は未校正の初期値だったため、正例と対照で実測しました(2026-08-27)。

- 正例: `soccer_goal`(ゴールは t = 6.0-8.0 秒)、対照: `soccer_idle`
- UI と同じ rolling window: stride 1 秒、window 4 秒、2 fps、最大 16 frame、2 token、cooldown 8 秒
- gate を 0 に開いて 1 回だけ流し、window ごとの `p_speak` と label を記録して、
  閾値は事後にスイープした(`calibrate_soccer.py`)

### frames backend では、どの閾値でも成立しない

| window | `soccer_goal` の p | label | `soccer_idle` の p | label |
|:---|---:|:---|---:|:---|
| 0-4 秒 | 0.0010 | none | 0.0002 | none |
| 1-5 秒 | 0.0001 | none | 0.0003 | none |
| 2-6 秒 | 0.0001 | none | 0.0005 | none |
| 3-7 秒 | 0.0003 | none | 0.0018 | none |
| 4-8 秒 | 0.0004 | **goal** | 0.0007 | none |

frames backend の `p_speak` は最大でも `0.0018` でした。**出荷時の閾値 `0.1` では
全 window が gate で落ち、検出は 1 件も出ません。** 閾値 0 にして初めて 1 件出ますが、
それも t = 8.0 秒で、event 開始から 2 秒遅れます。

### codec backend では発生と同時に検出する

| window | `soccer_goal` の p | label | `soccer_idle` の p | label |
|:---|---:|:---|---:|:---|
| 0-4 秒 | 0.7994 | none | 0.7814 | none |
| 1-5 秒 | 0.8834 | none | 0.8605 | none |
| 2-6 秒 | 0.7203 | **goal** | 0.8497 | none |
| 3-7 秒 | 0.7511 | **goal** | 0.7963 | **goal** |
| 4-8 秒 | 0.6924 | **goal** | 0.7724 | **goal** |

codec では最初の `goal` が window 2-6 秒、つまり **event 開始と同じ t = 6.0 秒**に出ました。
閾値スイープでは 0 から 0.7 までどこでも同じ結果で、0.8 以上にすると検出が消えます。

| 閾値 | `soccer_goal` | `soccer_idle` |
|---:|:---|:---|
| 0.00 - 0.70 | 検出 1 件、t = 6.0 秒 | 誤検出 1 件、t = 7.0 秒 |
| 0.80 - 0.90 | 検出 0 件 | 誤検出 0 件 |

### 解釈と preset の修正

- gate は学習ドメインが codec 入力であり、frames 入力では確率がほぼ 0 に張り付く。
  **frames backend と非ゼロの gate threshold の組み合わせは、設定として成立しない**
- codec でも gate はゴールと通常のプレーを区別しない(0.69-0.88 と 0.77-0.86 で重なる)。
  判定しているのは生成された label であり、gate は content type の pre-filter でしかない。
  これは既存 lab の結論と一致する
- `soccer_idle` は対照として不完全で、`goal` label を 1 件出した。生成時に「シュートなし」と
  指示したにもかかわらずシュート様の映像になっている問題は
  [`mage-vl-gate-event-correlation`](../../26/mage-vl-gate-event-correlation/README.md)で
  既に記録されている。したがってこの 1 件を確定的な false positive とは扱わない
- この結果を受けて OSS の preset を codec backend・threshold `0.3` に変更した。カメラモードは
  frames しか使えないため、frames に切り替わったときは threshold を 0 に落とす

正例 1 本・対照 1 本での測定なので、precision / recall を数値として主張できる規模ではありません。
成立するのは「frames + 非ゼロ閾値は動作しない」「codec なら event 時刻に一致して検出できた」
という 2 点だけです。

## 未確認事項と制約

- 実写と長尺 stream は未測定
- 本 lab の固定入力 matrix は動画ファイルを使う。カメラの結果は同じ入力ではないため、
  同じ機種の固定動画 matrix とも直接比較しない
- カメラの結果は 1 回のセッションであり、3 回の中央値をとっていない
- dtype 比較は 4 秒 segment だけで、他の segment 長では未測定
- この動画の gate 確率は閾値から離れているため、dtype による speak / silent の反転は
  この lab では検証していない
- 量子化、より長い segment、より少ない生成 token で M1 Max が RTF 1 を切れるかは未測定
- goal preset の校正は正例 1 本・対照 1 本のみで、precision / recall を主張できる規模ではない
- 対照の `soccer_idle` は生成指示どおりの「シュートなし」映像になっておらず、
  クリーンな negative ではない
- `mx.clear_cache()` の実行コストは未測定。解放後に cache が戻る速さだけを測った
- cold start の原因は page cache と解釈したが、`purge` による直接の反証実験はしていない
- UI 描画とブラウザ capture の overhead は本 runner に含まない。UI は同じ計測点を表示する
- gate の履歴再評価は stream が長くなるほど高コストになる可能性がある

## 参照

- [Mage-VL streaming gate はイベント時刻を追うか](../../26/mage-vl-gate-event-correlation/README.md)
- [Stage 4: codec-native sparse video](../../26/mage-vl-mlx-stage4-codec-native/README.md)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)
- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)
