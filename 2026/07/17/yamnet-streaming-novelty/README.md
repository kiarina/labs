# YAMNet streaming acoustic novelty detection

音声ストリーム中の突発的な変化を、単純な周波数変化と YAMNet の出力変化から
リアルタイムに検知できるか検証します。既知クラスを当てる sound event
detection ではなく、正常音または直前の音から離れたことを検出する acoustic
novelty detection として評価します。

## Purpose

明らかにしたい問いは次のとおりです。

- 32 ms の spectral flux は突発音を低遅延で検知できるか
- YAMNet の 521 次元 class score と 1,024 次元 embedding のどちらが、正常音から
  の逸脱をよく表すか
- 正常集合への k-nearest-neighbor 距離と、直前 frame からの cosine 距離の
  どちらが有効か
- 評価音を実時間より速く逐次処理できるか

主評価では、校正用の正常ストリームで一度も alert を出さない厳しいしきい値を
使います。しきい値に依存しない比較として、各ストリームの最大 anomaly score に
よる AUROC も報告します。

## Input and split

[ESC-50](https://github.com/karolpiczak/ESC-50) の revision
`33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6` から、必要な WAV 208 本だけを取得します。
ESC-50 全体は CC BY-NC です。

正常音は次の 4 category です。

```text
rain, sea_waves, wind, clock_tick
```

fold は用途ごとに分離します。

| 用途 | fold | clip 数 |
|---|---:|---:|
| 正常 reference memory | 1–3 | 96 |
| しきい値校正 | 4 | 32 |
| 誤警報評価 | 5 | 32 |

突発イベントは fold 5 の次の 6 category、各 8 clip です。

```text
crying_baby, door_wood_knock, glass_breaking,
siren, car_horn, fireworks
```

各イベント clip から、100 ms 移動 energy が最大になる位置を中心に 1 秒を切り出し、
fold 5 の正常 clip の 2.0–3.0 秒へ挿入します。event-to-background ratio は
`-10, -5, 0, +5 dB` とし、各条件 12 stream、合計 48 positive stream を生成します。
乱数 seed は `20260717` です。生成した stream はメモリ内だけで使用し、ファイルには
保存しません。

この split では正常 reference、しきい値、最終評価に同じ録音を使いません。一方、
ESC-50 は clip-level label しか持たないため、切り出した 1 秒がイベント全体を表すとは
限りません。挿入位置だけが正確な ground truth です。

## Model

[YAMNet の公式 TensorFlow SavedModel](https://www.tensorflow.org/tutorials/audio/transfer_learning_audio)
を使用します。

```text
URL: https://tfhub.dev/google/yamnet/1?tf-hub-format=compressed
archive SHA-256: b80da2a1a56926fb0767205051a200dd7b3beaf3ea1ea126c42a53943996e5e0
input: waveform [samples], 16 kHz mono float32
outputs:
  scores      [frames, 521]
  embeddings  [frames, 1024]
  spectrogram [frames, 64]
```

ストリームは 15,600 samples、0.975 秒の ring window として扱い、7,680 samples、
0.48 秒ごとに 1 frame を推論します。0.96 秒の audio patch に最初の出力を得るには
最低 0.975 秒が必要という公式実装に合わせています。

既存の YAMNet TFLite classifier は public output が `[1, 521]` の class score
だけで、embedding を出力しません。そのため本検証では、embedding 抽出を公開 API
として提供する SavedModel を使います。`tensorflow-hub` は実行時依存にせず、hash を
検証した archive を `tf.saved_model.load` で直接読み込みます。

## Detectors

### Spectral flux

16 kHz waveform を 512 samples、32 ms の Hann window と 256 samples、16 ms の hop
で処理します。各 magnitude spectrum を総和 1 に正規化し、直前 frame から増加した
bin の合計を anomaly score とします。

### YAMNet temporal distance

直前の YAMNet frame との cosine distance を使います。

```text
score_delta     = 1 - cosine(scores[t], scores[t-1])
embedding_delta = 1 - cosine(embedding[t], embedding[t-1])
```

両方の alert を OR し、0.5 秒以内の alert をまとめたものを `temporal_fusion` とします。

### YAMNet normal-reference distance

fold 1–3 の正常 frame を memory bank とし、5-nearest-neighbor への cosine distance
平均を anomaly score とします。

```text
score_knn     = 1 - mean(top-5 cosine score similarities)
embedding_knn = 1 - mean(top-5 cosine embedding similarities)
```

1,024 次元に対して正常 sample 数が少ないため、完全共分散を必要とする Mahalanobis
distance は使いません。

## Thresholds and evaluation

主しきい値は、fold 4 の正常 32 stream それぞれの最大値を求め、その最大値に設定します。
比較対象の fold 5 を見て調整していません。主しきい値は次のとおりでした。

| detector | threshold |
|---|---:|
| spectral flux | 1.000000 |
| score delta | 0.924936 |
| embedding delta | 0.583392 |
| score kNN | 0.831133 |
| embedding kNN | 0.458223 |

48 positive stream について event-based precision、recall、F1 と、挿入開始から alert
までの遅延を測ります。32 negative stream、合計 160 秒は誤警報評価だけに使います。
連続した active frame は 1 alert にまとめます。

また、最初に試した frame-level percentile threshold の結果も JSON report に残します。
YAMNet は 99th percentile、spectral flux は 99.5th percentile でした。

## Observed results

### Threshold-independent ranking

positive stream はイベントと重なる区間の最大値、negative stream は全区間の最大値で
AUROC を計算しました。

| detector | AUROC | -10 dB | -5 dB | 0 dB | +5 dB |
|---|---:|---:|---:|---:|---:|
| spectral flux | 0.449 | 0.393 | 0.315 | 0.555 | 0.534 |
| score delta | 0.717 | 0.622 | 0.672 | 0.776 | 0.797 |
| embedding delta | **0.734** | 0.638 | 0.625 | 0.815 | **0.859** |
| score kNN | 0.661 | 0.484 | 0.698 | 0.789 | 0.672 |
| embedding kNN | 0.632 | 0.479 | 0.581 | 0.721 | 0.745 |

YAMNet では、正常 reference への距離より直前 frame からの変化量の方が event と
negative stream をよく順位付けしました。embedding delta は最高 AUROC でしたが、
score delta との差は 0.018 で、この 80 stream だけから優劣を一般化はできません。

### Strict calibrated threshold

| detector | precision | recall | F1 | negative false alerts/hour | latency median | latency p95 |
|---|---:|---:|---:|---:|---:|---:|
| spectral flux | 0.000 | 0.0% | 0.000 | 0.0 | — | — |
| score delta | 0.810 | 35.4% | 0.493 | 22.5 | 0.415 s | 1.855 s |
| embedding delta | 0.765 | 27.1% | 0.400 | 22.5 | 0.415 s | 1.855 s |
| score kNN | 1.000 | 6.2% | 0.118 | 0.0 | 0.895 s | 1.327 s |
| embedding kNN | 0.800 | 16.7% | 0.276 | 0.0 | 0.895 s | 1.687 s |
| spectral + embedding kNN | 0.800 | 16.7% | 0.276 | 0.0 | 0.895 s | 1.687 s |
| score delta + embedding delta | **0.786** | **45.8%** | **0.579** | 22.5 | **0.415 s** | 1.855 s |

`temporal_fusion` は 48 event 中 22 件を検出しました。SNR 別の recall は次のとおりです。

| SNR | detected | recall | latency median |
|---:|---:|---:|---:|
| -10 dB | 4/12 | 33.3% | 1.855 s |
| -5 dB | 3/12 | 25.0% | 0.415 s |
| 0 dB | 7/12 | 58.3% | 0.415 s |
| +5 dB | 8/12 | 66.7% | 0.415 s |

イベント別では `glass_breaking` が 6/8、`fireworks` が 5/8、`car_horn` が 4/8
でした。`crying_baby` と `siren` は各 2/8 で、1 秒だけの切り出しや背景との混合に
強く影響されました。

negative false alert は 160 秒中 1 件だけです。これを 1 時間へ換算した 22.5 件/時は
推定分散が非常に大きく、実運用可能な誤警報率を示すものではありません。少なくとも
数時間の連続背景音による再評価が必要です。

### Failed threshold and fusion attempts

frame-level percentile threshold では `temporal_fusion` の recall は 58.3% まで上がり
ましたが、negative false alert は 112.5 件/時でした。spectral flux は recall 29.2%
に対して 967.5 件/時でした。自然背景の spectral change が多く、単純な正規化
spectral flux は突発事態の detector として機能しませんでした。

当初想定した spectral flux と embedding kNN の融合も、厳しいしきい値では embedding
kNN 単体と同じ 16.7% recall でした。緩いしきい値では recall 45.8% に対して
607.5 false alerts/hour となり、改善ではありませんでした。

### Audio labels during inserted events

YAMNet の top label は `glass_breaking` 8 件中 3 件で `Glass` でしたが、低 SNR では
背景の `Water`、`Rain`、`Vehicle` などが多く残りました。novelty score が高いことと、
521 class の top label が挿入イベントを説明できることは別の問題です。

### Processing time

Mac Studio (Apple M4 Max) で 1,040 秒分を逐次 window として処理した結果です。

```text
feature extraction elapsed: 6.262 s
real-time factor:           0.0060x
```

時間は YAMNet SavedModel 推論と spectral flux を含み、model load、warm-up、FFmpeg
decode、download、kNN score 計算は含みません。スループットには十分な余裕がありますが、
YAMNet の 0.975 秒 window と 0.48 秒 hop により、検出遅延の最短観測値は 0.415 秒でした。

## Interpretation

この条件では、YAMNet をストリームから繰り返し推論する計算性能は十分でした。ただし、
正常 embedding memory への単純な kNN 距離は未知イベント検出器として弱く、低 SNR では
正常背景との距離に埋もれました。今回の突発イベントには、正常集合との大域的な距離より、
直前 frame からの局所的な変化が適していました。

一方、最良の `temporal_fusion` でも strict threshold の recall は 45.8% です。このまま
実運用できる精度ではありません。「YAMNet embedding を使えば未知の突発音を安定して
検出できる」という当初仮説は、この検証では支持されませんでした。

次に確認すべき改善は次のとおりです。

- 数時間の連続正常音で false alerts/hour としきい値を再推定する
- cosine delta を CUSUM や Page-Hinkley で累積し、単発 threshold と比較する
- 音量上昇を捨てない multi-band energy rise を高速経路へ追加する
- YAMNet hop を 0.24 秒へ短縮したときの遅延と誤警報を比較する
- [DCASE 2017 Rare Sound Events](https://dcase.community/challenge2017/task-rare-sound-event-detection)
  の正確な onset/offset 付き 30 秒 mixture で追試する
- 実マイク入力では callback と推論 worker を分離し、queue overflow も測る

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- FFmpeg
- 初回実行時にインターネット接続
- 約 120 MB の model/data と、約 1.3 GB の Python environment

リポジトリルートから実行します。

```sh
mise -C 2026/07/17/yamnet-streaming-novelty run
```

初回は model と選択した ESC-50 WAV を `models/`、`data/` へ取得します。結果は
`output/report.json` へ保存します。これらは Git の管理対象外です。

## Verification environment

- machine: Mac Studio (Mac16,9)
- chip: Apple M4 Max
- OS: macOS 26.5.2, arm64
- Python: 3.12.10
- TensorFlow: 2.21.0
- NumPy: 2.3.5
- FFmpeg: 8.1.2
- random seed: 20260717
