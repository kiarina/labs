# Apple SpeechAnalyzer Japanese streaming ASR

Apple SpeechAnalyzerの`SpeechTranscriber`へ日本語音声を実時間相当で逐次入力し、
確定文字列の文字誤り率とprogressive transcriptionの途中結果遅延を検証します。
同じ処理をマイクで試すため、browserのFloat32 PCMをlocalhost経由でSwift CLIへ渡す
Web UIも用意します。

## Purpose

明らかにしたい問いは次のとおりです。

- 既知の日本語会話を実時間相当で入力したとき、確定結果の文字誤り率（CER）はどの程度か
- 正確さ優先の`transcription`と途中結果を返す`progressiveTranscription`で結果が変わるか
- progressive modeの最初の途中結果と、音声時刻に対する結果配送遅延はどの程度か
- browser microphoneからSpeechAnalyzerまでのローカルstreaming経路を構成できるか

事前の評価基準は、確定CER 10%以下、6発話の内容欠落なし、最初の途中結果1秒未満、
途中結果配送遅延p95 1秒未満としました。RTFは入力を意図的に実時間で待ちながら送るため、
推論性能ではなく、入力開始から最終確定までのwall timeを示します。

## Input and conditions

共有test assetの2話者日本語会話を使用します。

```text
tests/assets/mp3/conversation_2speaker_14s_16k.mp3
```

taskはFFmpegで16 kHz mono PCM WAVへ変換してからSwiftへ渡します。MP3を
`AVAudioFile`で直接読むとencoder paddingを含む14.256秒として扱われましたが、FFmpegで
decodeしたWAVは既存labと同じ14.171秒になりました。比較条件を揃えるため後者を採用します。

- locale: `ja_JP`
- input: 16 kHz、mono、Int16 PCM
- input chunk: 100 ms
- pacing: 各chunkの音声時間だけ待つ実時間相当入力
- presets: `SpeechTranscriber.Preset.transcription`、`.progressiveTranscription`
- trials: 各3回
- CER normalization: 空白、改行、句読点を除去し、小文字化
- model asset: macOSの`AssetInventory`が管理するインストール済み日本語asset

Appleのmodel assetはsystemが管理・更新するため、通常のcheckpointのようにrevisionやhashを
固定できません。追試ではOS build、Speech framework、localeを同時に記録する必要があります。

## Run

必要なものはApple Silicon Mac、macOS 26以降、Xcode Command Line Tools、mise、uv、
FFmpegです。リポジトリルートから次を実行します。

```sh
mise -C 2026/07/20/apple-speech-analyzer-streaming-asr run
```

共有asset取得、Swift test、release build、本計測を順に行います。結果はGit管理外の
`output/report.json`へ保存します。

### Microphone Web UI

```sh
mise -C 2026/07/20/apple-speech-analyzer-streaming-asr run demo
```

表示された`http://127.0.0.1:8000`を開き、`マイクを開始`を押します。AudioWorkletは
browserのnative sample rate（Macでは通常48 kHz）のmono Float32 PCMを
WebSocketで`127.0.0.1:8765`へ送ります。Python bridgeはchunk境界をまたいで16 kHzへ連続
resampleし、100 ms単位でrelease build済みSwift processへ渡します。Swift側ではモデルが
要求するInt16 PCMへ変換します。

途中結果はlime色、確定結果は白色で表示します。`停止して確定`を押すとマイクtrackと
AudioContextを閉じ、SpeechAnalyzerをfinalizeします。音声はlocalhostのprocess間だけを流れ、
外部serviceへ送信も保存もしません。serverには認証がないため外部公開しないでください。
状態欄にはbridgeへ届いた音声時間と1秒窓のRMS levelを表示します。発話中も`無音`または
-60 dBFS以下が続く場合は、入力デバイス欄で内蔵マイクなど使用するdeviceを明示的に選びます。
取得した音声track名と、接続中・ミュート・終了の状態も同じ欄で確認できます。

browserを自動で開かない場合は次を使います。

```sh
mise -C 2026/07/20/apple-speech-analyzer-streaming-asr run demo --no-open
```

## Observed results

3回ずつの結果は次のとおりでした。

| Preset | CER | Partial results | First partial | Partial delivery lag p50 / p95 | Final delivery lag | End-to-end RTF |
|---|---:|---:|---:|---:|---:|---:|
| transcription | 0.0% × 3 | 0 | — | — | 1.160–1.215 s | 1.078–1.086 |
| progressive | 0.0% × 3 | 93、93、94 | 1.082–1.101 s | 0.526 / 1.014 s | 1.033–1.223 s | 1.072–1.086 |

CERでは数字の前後の空白、句読点を無視しています。全6発話の内容は全試行で保持されました。
句読点は試行間およびpreset間で異なり、たとえば「そっちはこっちは」と
「そっちは。こっちは」の差がありました。

`transcription`は途中結果を返さず、3回とも入力終了後に1個の確定結果を返しました。
`progressiveTranscription`は約1.09秒で最初の途中結果を返し、その後は累積文字列を更新し、
入力終了時に1個の確定結果を返しました。progressiveの全280途中結果をまとめた配送遅延は
p50 0.526秒、p95 1.014秒でした。

したがって、CER 10%以下と発話欠落なしは満たしました。一方、最初の途中結果1秒未満と
途中結果配送遅延p95 1秒未満はわずかに満たしませんでした。

Web経路は、同じ14.171秒音声を48 kHz Float32 PCMへ変換し、AudioWorklet相当の128 frame
ずつWebSocketへ送るE2E testで確認しました。bridgeで16 kHzへ変換後、93件の途中結果と
1件の確定結果を受信し、最終文字列はbenchmarkと同じ内容を保持しました。実マイクの音質や
browser permission UIは自動testの対象外です。

### Qualitative microphone trial

ChromeとMacBook Pro内蔵マイクを使った1名の自由発話では、利用者は表示遅延を体感約1秒で
「割と早い」と評価しました。誤認識は多少あるものの少ないという評価で、具体例として
`十分`と`10分`の表記上の取り違えがありました。一方、句読点は必要な位置に付かないことが
あり、もっと多く付いてよいという評価でした。

これは発話script、正解transcript、計時を用意しない主観評価であり、上記benchmarkの測定値や
CERとは別の観測です。ただし約1秒という体感は、最初の途中結果約1.09秒、配送遅延p95
約1.01秒という測定結果と整合します。

## Interpretation

### Observed facts

- この固定会話では、両presetとも全試行で正規化CER 0%だった
- progressive modeは文字列を逐次更新できたが、最初の表示まで約1.09秒かかった
- progressiveのp95配送遅延は約1.01秒で、低遅延字幕としては目に見える遅れがある
- 48 kHz Float32 chunkをbrowser相当の単位で送り、16 kHzへ変換して解析できた

### Interpretation and inference

この入力では、SpeechTranscriberの日本語内容認識は正確でした。ただし1本のcleanな合成会話に
対する結果であり、一般的な日本語ASR精度を示しません。progressive modeは対話的な表示には
使えますが、単語を話した直後に即座に表示される水準ではありません。

`transcription`と`progressiveTranscription`の最終CERが同じだったことから、この入力では
`.fastResults`相当の設定による最終内容の劣化は観測されませんでした。長文、固有名詞、雑音、
遠距離収音では結果が変わる可能性があります。

## Failed attempts and reproducibility notes

最初のstreaming実装は、`AVAudioFile.processingFormat`のFloat32 bufferを
`AnalyzerInput`へ直接渡し、Speech framework内の`SpeechRecognizerWorker.preRunRecognition()`
でSIGTRAPになりました。`bestAvailableAudioFormat`が返した形式は16 kHz Int16でした。
各chunkを要求形式へ変換して解決しました。sample rateとchannel数だけでなく、PCM sample
formatまで一致させる必要があります。

また、feederがEOFでもう一度`AVAudioFile.read`を呼ぶと`nilError`になり、AsyncStreamが
終了せず解析が待ち続けました。`framePosition < length`を事前確認し、`defer`で必ずstreamを
finishするようにしました。

Web UIの初期実装は、`AudioContext({ sampleRate: 16000 })`の指定が常に採用されると仮定し、
browserの実sample rateをそのままSwiftへ渡していました。48 kHzで動作する環境では、
SpeechAnalyzerの日本語modelが要求する16 kHz Int16形式と一致せずprocessが終了しました。
bridgeで連続resampleしてから常に16 kHzとしてSwiftへ入力するよう修正しました。その後、
browser側で16 kHzを強制する必要もなくなったため、native rateでcaptureする構成にしました。

## Verification environment

- machine: MacBook Pro (MacBookPro18,2)
- chip: Apple M1 Max、10 cores
- memory: 64 GB
- OS: macOS 26.5.2 (25F84), arm64
- Xcode: 26.6 (17F113)
- Swift: 6.3.3
- Speech locale: `ja_JP`
- Python: 3.12.10
- websockets: 15.0.1
- FFmpeg: 8.1.2
- uv: 0.10.8
- mise: 2026.7.7

## Limitations

- cleanな合成会話1本、1種類の内容、2話者、14.171秒だけを評価した
- CERは句読点と空白を無視し、句読点品質を定量評価していない
- 実マイクの所感はChrome・内蔵マイク・1名による自由発話の主観評価に限られる
- Apple管理modelの正確なversionとhashを固定できない
- 遠距離、雑音、残響、実在話者、方言、固有名詞、長時間streamを評価していない
- マイクcapture latency、audio device buffer、browser permission待ちをbenchmarkに含めていない
- energy使用量、system processを含むmemory、複数同時sessionを測定していない
- Web UIの自動E2E testは既知音声の疑似マイク入力であり、実マイク品質を保証しない

## References

- [SpeechAnalyzer documentation](https://developer.apple.com/documentation/Speech/SpeechAnalyzer)
- [SpeechTranscriber documentation](https://developer.apple.com/documentation/speech/speechtranscriber)
- [SpeechTranscriber presets](https://developer.apple.com/documentation/speech/speechtranscriber/preset)
- [WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
