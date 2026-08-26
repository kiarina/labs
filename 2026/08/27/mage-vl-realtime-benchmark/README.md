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

## 未確認事項と制約

- 実写と長尺 stream は未測定
- カメラは Web UI の動作確認を行ったが、本 lab の固定入力 matrix は動画ファイルを使う
- MacBook Pro M1 Max は未測定
- UI 描画とブラウザ capture の overhead は本 runner に含まない。UI は同じ計測点を表示する
- gate の履歴再評価は stream が長くなるほど高コストになる可能性がある

## 参照

- [Mage-VL streaming gate はイベント時刻を追うか](../../26/mage-vl-gate-event-correlation/README.md)
- [Stage 4: codec-native sparse video](../../26/mage-vl-mlx-stage4-codec-native/README.md)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)
- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)
