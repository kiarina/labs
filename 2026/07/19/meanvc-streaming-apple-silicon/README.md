# MeanVC streaming zero-shot voice conversion on Apple Silicon

MeanVC の公開済み 200 ms streaming runtime を使い、参照音声だけで話者を指定する
zero-shot voice conversion が Apple Silicon の CPU でリアルタイム処理できるか検証します。

## Purpose

明らかにしたい問いは次のとおりです。

- 200 ms ごとの変換を deadline 内に継続して処理できるか
- chunk 推論時間の p50、p95、p99 と deadline miss 率はどの程度か
- 変換音声の話者 embedding は source より target reference に近づくか
- chunk 境界に、通常の隣接 sample 差より大きな不連続が生じるか

本検証では、実マイクを使わず、音声ファイルを実マイクと同じ chunk 順序で逐次処理
します。変換の計算余裕とモデル内の algorithmic latency を対象とし、Core Audio や
仮想オーディオデバイスの buffer latency は測定しません。

## Input

共有 test asset の 2 話者による 14.171 秒の会話を使用します。

```text
tests/assets/mp3/conversation_2speaker_14s_16k.mp3
```

既知の発話境界から Speaker 1 の 3 発話を source、Speaker 2 の 3 発話を target
reference として連結します。source と target に同じ発話は含まれません。

| Use | Segments | Duration |
|---|---|---:|
| source | 0.000–1.851, 4.737–7.317, 9.677–11.834 s | 6.588 s |
| target reference | 1.851–4.737, 7.317–9.677, 11.834–14.171 s | 7.583 s |

source は「もしもし、もう駅に着いた？」「こっちはまだ電車。あと5分くらいかな。」
「助かる。今日は結構寒いね。」の3発話です。target reference は別話者による残りの
3発話です。

## Models

[MeanVC](https://github.com/ASLP-lab/MeanVC) は streaming ASR、speaker/timbre
encoder、MeanFlow DiT、Vocos vocoder からなる zero-shot voice conversion model
です。公開 runtime の microphone path と同じ `inference_one_chunk` を使用します。
code と Hugging Face model は Apache-2.0 です。

```text
MeanVC source revision: b07024579284975bc8a6a9aa72201d6279b417ab
MeanVC model revision:  2e2a116d1b1fdd0957c730be5cef3cd2ddf16779
```

使用する checkpoint は次のとおりです。

| File | Role | SHA-256 |
|---|---|---|
| `fastu2++.pt` | streaming content encoder | `4d6bc429...fe9512a1` |
| `meanvc_200ms.pt` | voice conversion model | `17a23494...5237c68f` |
| `vocos.pt` | causal vocoder | `9e8aba28...7e2f281` |
| `wavlm_large_finetune.pth` | target speaker/timbre encoder | `51f07e3b...fe7f94b` |

upstream runtime は `torch.hub.load("s3prl/s3prl", "wavlm_large")` を使い、実行時の
`main` branch と mutable な model URL に依存していました。本 lab では再現性のため、
[S3PRL](https://github.com/s3prl/s3prl) source revision
`ec8064b5889f81ca460fbe2c094ce576a6f120b7` と WavLM model revision
`8cad0b370e7e35f8d56951d95d2be036ea85510c` を固定し、local source から読み込みます。
upstream の MeanVC source 自体は変更しません。

話者変換の評価には、MeanVC の WavLM encoder とは独立した
[`pranjal-pravesh/ecapa_tdnn_onnx`](https://huggingface.co/pranjal-pravesh/ecapa_tdnn_onnx)
revision `04c3ffe4fd00b3b7853fd57db44e2e531d4817f2` を使います。16 kHz waveform
から192次元 embeddingを生成し、L2 normalize後のcosine similarityを比較します。

## Streaming conditions

- sample rate: 16 kHz mono
- execution: CPU TorchScript、1 thread
- MeanFlow inference steps: 2
- first input: 3,920 samples、245 ms
- steady input: 3,200 samples、200 ms
- warm-up: 1 chunk
- measured trials: 3
- chunks per trial: 33
- measured chunks: 99
- random seed: `20260719 + trial index`

公開 runtime は最初だけ 3,200 samples に 720 samples の追加 context を読み、その後は
3,200 samples ずつ処理します。各試行で ASR、DiT、vocoder の cache を初期化します。
推論時間が、その chunk をマイクから収録する時間を超えた場合を deadline miss とします。

first-output latency は `245 ms + first chunk inference` として推定します。model load、
target embedding抽出、audio decode、実オーディオデバイスの入出力bufferは含みません。

## Observed results

### Processing time

MacBook Pro、Apple M1 Max の CPU 1 thread での結果です。

| Measurement | p50 | p95 | p99 |
|---|---:|---:|---:|
| all chunk inference | 35.1 ms | 37.8 ms | 40.1 ms |
| steady 200 ms chunk inference | **35.1 ms** | **37.7 ms** | **38.0 ms** |

```text
deadline misses:       0 / 99
deadline miss rate:    0.0%
steady maximum:        38.4 ms
peak resident memory:  2,849 MB
```

steady p95 は 200 ms deadline の18.8%でした。この入力と実行中の負荷では、CPU 1 thread
だけで連続処理する計算余裕がありました。

3試行の first chunk inference は約32、32、122 msとばらつきました。推定
first-output latency は p50 約277 ms、p95 約359 ms、最大約368 msです。steady processingが速いことは、
発話開始直後の遅延が小さいことを意味しません。

source 6.588 秒から 6.570 秒の変換音声を生成しました。18 ms の差は最後のpaddingと
vocoder overlap処理によるものです。

### Speaker similarity

| Pair | ECAPA cosine similarity |
|---|---:|
| source – target reference | 0.210 |
| converted – source | 0.320 |
| converted – target reference | **0.725** |

比較用に個々の発話を埋め込むと、source話者内3組の平均は0.486、target話者内3組の
平均は0.566、異なる話者間9組の平均は0.175でした。converted–targetの0.725は
異話者baselineを0.550上回り、このサンプルでは変換音声の話者embeddingがtarget側へ
明確に移動しました。

ECAPA cosineは声の自然さや本人同一性を保証する指標ではありません。また、今回の
convertedとtargetはいずれも複数発話を連結しているため、短い個別発話間の値と直接同じ
尺度として扱うことはできません。

### Chunk boundaries and signal

| Measurement | Value |
|---|---:|
| source RMS | -21.12 dBFS |
| target RMS | -22.37 dBFS |
| converted RMS | -19.98 dBFS |
| clipped samples | 0.0% |
| boundary jump p50 | 0.00781 |
| boundary jump p95 | 0.04618 |
| all adjacent sample jump p95 | 0.05674 |
| maximum boundary / overall jump | 0.134 / 0.532 |

32個のchunk境界について、境界差のp95は音声全体の隣接sample差p95より小さく、最大値も
音声全体の最大隣接差を下回りました。波形差だけを見る限り、chunk境界に系統的な大きな
不連続は観測されませんでした。ただし、これはclick noiseの聴感評価ではありません。

## Interpretation

この条件では「MeanVC 200 ms runtimeをApple M1 MaxのCPU 1 threadでdeadline内に処理
できる」という仮説は支持されました。99 chunkすべてがdeadline内で、steady p95には
約162 msの余裕があります。target話者への変換も独立したspeaker embeddingで確認できました。

一方、推定first-output latencyは約0.28–0.37秒であり、20–100 ms級の低遅延voice
changerではありません。オンライン会議や配信では利用可能な範囲になり得ますが、自己音声を
直接monitorする用途では遅延を強く感じる可能性があります。実機の音声bufferを追加した
end-to-end latencyは今回の値より大きくなります。

また、speaker similarityは確認できましたが、自然さ、発音保持、日本語の文字誤り率は評価
していません。「リアルタイムに計算でき、targetらしいembeddingになった」範囲を超えて、
高品質なvoice conversionであるとは結論できません。

### Applicability to Japanese and reference duration

日本語での利用は、今回の結果に影響した可能性があります。[MeanVC論文の実験条件](https://arxiv.org/html/2510.08392v3)
では、VC本体をEmiliaから抽出した10,000時間のMandarin音声で学習し、zero-shot評価にも
Seed-TTSのMandarin subsetを使用しています。sourceの内容特徴を抽出するFast-U2++も、
Mandarin中心のWenetSpeechで学習されています。したがって、日本語は論文で性能を確認した
言語分布の外です。

特に、Fast-U2++が日本語のモーラ、促音、長音、母音の無声化、pitch accentなどを十分に
表現できない場合、内容特徴にsource話者の発音・声質が残る、または必要な音響情報が失われる
可能性があります。その結果、global speaker embeddingがtargetを捉えていても、変換音声が
target本人に完全には似ないことが考えられます。ただし、本検証は日本語1入力と1話者pairだけ
なので、言語差による劣化を直接観測したとは結論できません。

referenceの長さも影響し得ます。短すぎるreferenceでは声域、母音・子音、抑揚を十分に観測
できません。一方で、長くても無音、noise、reverb、複数話者、異なる発話styleが混ざると、
speaker embeddingとreference melが不安定になる可能性があります。MeanVCの後継論文は、初代が
reference melへ直接依存するためreference品質に敏感であることを既知の制約として挙げています
（[MeanVC 2](https://arxiv.org/abs/2606.09050)）。実用上は、まず5–15秒程度のcleanな単一話者音声を
試すのが妥当ですが、この長さは本検証で確定した最適値ではありません。

言語とreference長の影響を分離するには、同一target話者・同一録音条件で次を比較する必要が
あります。

| Factor | Controlled comparison |
|---|---|
| reference duration | 同じ発話から1、3、5、10、20秒を切り出す |
| reference language | 同じbilingual話者の日本語とMandarinまたは英語を同じ長さで比較する |
| source language | 同じtarget referenceに対して日本語とMandarin sourceを変換する |
| streaming constraint | 同じpairを200 ms streamingとofflineで比較する |

ECAPA/WavLM similarityに加え、日本語ASRの文字誤り率とblind listeningによるspeaker similarityを
記録すれば、「referenceが短い」「日本語が学習分布外」「streaming model自体の上限」を
切り分けられます。

## Reproducibility notes and failed setup

最初の実行では、MeanVC runtimeがrepository rootからの起動を前提とするため `src` module
を解決できませんでした。lab loaderで固定revisionのrepository rootをmodule pathへ追加して
解決しました。

次に、target speaker encoderがS3PRLの`main` branchを動的取得し、未宣言のPyYAMLで停止
しました。単にPyYAMLを追加すると実行時点のcode/modelへ依存するため、S3PRL sourceと
WavLM checkpointもrevisionとSHA-256を固定しました。これにより初回取得量は約2.7 GiB、
peak resident memoryは約2.8 GiBになりました。軽量な14M parameterの変換本体だけではなく、
zero-shot target encoderが配布・メモリ量の大部分を占めます。

## Limitations

- 1本の短い日本語会話、1組のsource/target話者だけを評価した
- 実マイク、speaker出力、仮想audio device、callbackのqueue overflowを評価していない
- model loadとtarget embedding生成時間をlatencyに含めていない
- ECAPA similarity以外の自然さ、明瞭度、発音保持、主観評価を行っていない
- noise、歌声、笑い、ささやき、無音の長時間継続を評価していない
- PyTorch CPU runtimeだけを扱い、MPS、ONNX、Core MLへ変換していない
- 公開runtimeの固定200 ms構成だけを扱い、chunk sizeとのtrade-offを比較していない

voice conversionは本人の同意を得た音声だけに使用する必要があります。本検証では共有test
asset内の合成会話だけを使用し、実在人物の模倣用modelは作成していません。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- FFmpeg
- 初回実行時にインターネット接続
- model約2.7 GiBとPython environment用の空き容量

リポジトリルートから実行します。

### Browser demo

```sh
mise -C 2026/07/19/meanvc-streaming-apple-silicon run demo
```

ローカルserverが`http://127.0.0.1:8000`で起動し、browserを開きます。UIでは次の2通りを
試せます。

- `サンプルで試す`: 本検証と同じ合成会話からsourceとtargetを切り出して変換する
- 任意音声: sourceとtargetをそれぞれ選び、`VOICE CHANGE`を押す
- live microphone: targetを選び、`LIVE START`を押してマイク入力を連続変換する

sourceは変換したい発話、targetは声質の参照です。各音声は30秒以内、targetは1秒以上に
制限しています。初回変換時だけmodelの読み込みに数秒かかり、以降は同じprocess内のmodelを
再利用します。変換結果とrealtime factor、chunk p50、推論時間を画面に表示します。

live microphoneではbrowserのWeb Audio APIでマイク入力を取得し、16 kHz monoへresampleして
最初の245 ms、その後は200 ms単位でlocalhostへ送ります。serverは同じMeanVC cacheを保った
まま各chunkを変換し、browserは返されたPCMを順次再生します。音の回り込みを避けるため、
speakerではなくヘッドホンを使用してください。`STOP`を押すとマイク取得とlive sessionを
終了します。localhostはsecure contextとして扱われますが、初回はbrowserのマイク許可が必要です。

音声はlocalhost内だけで処理し、serverから外部serviceへアップロードしません。serverには
認証機能がないため、`--host 0.0.0.0`などを指定して外部公開しないでください。停止はterminalで
`Ctrl-C`を押します。自動でbrowserを開かない場合は次のように実行できます。

```sh
mise -C 2026/07/19/meanvc-streaming-apple-silicon run demo --no-open
```

### Benchmark

```sh
mise -C 2026/07/19/meanvc-streaming-apple-silicon run
```

最初に `mise run //:test-assets:download` を実行し、固定revisionのsourceとmodelを
`vendor/`、`models/`へ取得します。全ファイルのSHA-256を検証します。変換WAVとJSON
reportは`output/`に生成します。これらはGitの管理対象外です。

```text
output/
├── source.wav
├── target_reference.wav
├── converted.wav
└── report.json
```

## Verification environment

- machine: MacBook Pro (MacBookPro18,2)
- chip: Apple M1 Max
- memory: 64 GB
- OS: macOS 26.5.2, arm64
- Python: 3.11.15
- PyTorch: 2.5.1, CPU, 1 thread
- NumPy: 1.26.4
- ONNX Runtime: 1.27.0, CPUExecutionProvider
