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

## 未確認事項と制約

- 実写と長尺 stream は未測定
- 本 lab の固定入力 matrix は動画ファイルを使う。カメラの結果は同じ入力ではないため、
  Mac Studio の表と直接比較しない
- MacBook Pro M1 Max の固定動画 matrix は未測定で、カメラ入力の結果だけがある
- カメラの結果は 1 回のセッションであり、3 回の中央値をとっていない
- `mx.clear_cache()` の実行コストと、解放後に cache が再び伸びるまでの速度は未測定
- UI 描画とブラウザ capture の overhead は本 runner に含まない。UI は同じ計測点を表示する
- gate の履歴再評価は stream が長くなるほど高コストになる可能性がある

## 参照

- [Mage-VL streaming gate はイベント時刻を追うか](../../26/mage-vl-gate-event-correlation/README.md)
- [Stage 4: codec-native sparse video](../../26/mage-vl-mlx-stage4-codec-native/README.md)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)
- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)
