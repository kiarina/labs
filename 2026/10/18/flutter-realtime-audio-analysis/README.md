# Real-time microphone analysis in Flutter on macOS, Windows, Android, iOS and web

マイクの音を、端末の中でリアルタイムに解析できるかを確かめます。解析の中身は、Python の
[kiarina-python](https://github.com/kiarina/kiarina-python)（commit `9d483457`）の `kiarina-agi-audio` と
`kiarina-agi-data-builder` の音声の処理を Dart に移したものです。

| 処理 | モデル | Dart から使う道 |
| --- | --- | --- |
| 発話区間の検出（VAD） | Silero VAD（ONNX） | ONNX Runtime |
| 話者の切り替わり | pyannote-segmentation-3.0（ONNX） | ONNX Runtime |
| 文字起こし（ASR） | Whisper（whisper.cpp、ggml） | dart:ffi（ネイティブ）／WebAssembly（web） |
| 話者の埋め込み | ECAPA-TDNN（ONNX、192 次元） | ONNX Runtime |
| 環境音の埋め込み | CLAP HTSAT unfused（ONNX、512 次元） | ONNX Runtime ＋ Dart の log-mel |
| 環境音の分類 | YAMNet（kiarina と同じ TFLite を ONNX に変換） | ONNX Runtime |

流れは「マイクの許可 → モデルのダウンロード → マイクを点けると解析が始まる → 結果が溜まる → 後から道具で取り出す」です。
アプリの中の「brain の道具」は `recall`（直近 N 分に聞いたこと）として作りました。

## Purpose

1. Python と同じモデルを Dart から、5 つのプラットフォーム（macOS・Windows・Android・iOS・web）で動かせるか
2. Dart に移した処理と、各プラットフォームの推論が、Python と同じ結果を出すか
3. ローカルの Whisper を既定にして、リアルタイムに追いつくか。どこが遅いか
4. 許可・ダウンロード・マイク・解析・取り出しの一連の流れが、各プラットフォームで通るか
5. 解析を、アプリから切り離せる独立したパッケージとして書けるか

## Answer

- **5 つのプラットフォームすべてで、6 つの処理が動きました。** ONNX のモデル 5 つは、どのプラットフォームでも
  Python（onnxruntime 1.31、macOS arm64）と同じ値を出しました（下の表。埋め込みのコサイン類似度は 1.000000、
  Silero VAD の確率の差は 1e-6 以下）。Dart に移した前処理と後処理（PCM の変換、48 kHz への変換、発話の切り出し、
  話者の切り替わりの判定）は Python とビット単位または区間単位で一致し、CLAP の log-mel の差は最大 7.6e-6 dB でした
- **ローカルの Whisper は、デスクトップ・iOS・web では実時間に余裕で追いつきます。** 1〜2.5 秒の発話 1 つの文字起こしは、
  macOS（Metal）で 45〜108 ms、iPad Air 4（Metal）で 108〜219 ms、Windows（CPU）で 0.19〜1.06 s、iOS シミュレータ（CPU）で 0.3〜0.4 s、
  web（WebAssembly、8 スレッド）で 0.45〜0.98 s（base、`audio_ctx` を縮めたとき）
- **Android（Pixel 6）の CPU は、そのままでは追いつきません。** Whisper は短い発話でも 30 秒の枠で計算するので、base で
  1 発話 3.8〜4.7 s かかりました。枠を発話の長さに縮める（whisper.cpp の `audio_ctx`）と 0.7〜1.3 s になり、全体で実時間の
  0.63 倍の処理時間に収まりました。代わりに、同じ文の繰り返しや聞き違いが少し増えます
- **結果が出るまでの遅れは、Whisper より発話の区切り方で決まります。** kiarina の設定（無音 500 ms で区切る）では、この会話は
  14 秒が 1 つの発話になり、文字起こしが会話の終わりにまとめて出ました（終わりから 4.6〜12.6 s）。無音 300 ms・最長 8 秒で
  区切ると、8 件中 5 件が 1.5 s 以内に出ます（macOS）。最長で切った区間だけは約 6 s 遅れ、話者を 1 人多く数える誤りも 1 回出ました
- **一連の流れ（許可 → ダウンロード → マイク → 解析 → 取り出し）を、iPad Air 4 の本物のマイクで人が 90 秒話して通しました。**
  取りこぼしは 0、VAD は実時間の 0.07 倍、Whisper small は 0.67 倍で追いつきました。web は Chrome の偽のマイクで通し、
  macOS・Windows・Android・iOS シミュレータは同じ音声をマイクの代わりに 100 ms ずつ実時間で流して通しました
- **本物のマイクで、2 つの弱点が出ました。** (1) 0.4〜0.7 秒の短い区間（話者の判定が無音・重なり）を Whisper にかけると、
  「ご視聴ありがとうございました!」という、無音のときの Whisper の典型の作り話が 5 回出た。(2) 話者の埋め込みのしきい値
  （kiarina の 0.45）では、短い発話ごとに新しい話者になり、1 人で話した 90 秒が 9 人に分かれた。どちらも kiarina と同じ挙動で、
  直し方（短い区間や話者でない区間を ASR にかけない、短い発話では話者を新しく作らない）は下の「確かめていないこと」
- **kiarina-python の不具合を 2 つ見つけました。** YAMNet の TFLite は 10 秒の窓の最初の 0.975 秒しか見ず、0.975 秒より短い
  音では落ちます。Dart 版は窓全体を 0.975 秒ずつ見るように直しました（`firstCropOnly` で kiarina と同じにもできる）
- **解析はアプリから切り離したパッケージ `packages/audio_analysis` に書けました。** ASR は口（`Asr`）だけを持ち、whisper.cpp は
  別のパッケージ `packages/whisper_cpp` です

## Results

### モデルが Python と同じ値を出すか（parity）

アプリの parity モードで、各プラットフォームの推論を Python の出力（`fixtures/`）と比べました。入力は 14 秒の 2 人の会話
（下の「Input」）。`results/parity-*.json`。

| プラットフォーム | Silero 確率の最大差 | 0.5 での判定の一致 | Silero 1 回 (ms) | pyannote 確率の最大差 | ECAPA コサイン（最小、6 発話） | CLAP コサイン（最小、2 窓） | YAMNet スコアの最大差 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| macOS | 5.0e-07 | 100% | 0.55 | 5.0e-07 | 1.000000 | 1.000000 | 0 |
| Windows | 7.9e-07 | 100% | 0.60 | 1.3e-06 | 1.000000 | 1.000000 | 0 |
| Android | 5.0e-07 | 100% | 5.08 | 5.6e-07 | 1.000000 | 1.000000 | 0 |
| iOS シミュレータ | 5.0e-07 | 100% | 0.82 | 5.0e-07 | 1.000000 | 1.000000 | 0 |
| web（Chrome） | 8.5e-07 | 100% | 0.31 | 1.2e-05 | 1.000000 | 1.000000 | 0 |
| iPad Air 4 | 5.0e-07 | 100% | 0.53 | 1.2e-06 | 1.000000 | 1.000000 | 0 |

- YAMNet の差は、同じ ONNX を Python の onnxruntime で動かした値との差です。元の TFLite との差は、量子化の幅（1/256）の
  2〜4 倍まで（上位 3 件は window 0 で一致、window 1 で 2・3 位が入れ替わる）。変換の詳細は `tools/README.md`
- Silero 1 回は 512 サンプル（32 ms）の呼び出しの中央値。Android の 5 ms でも 32 ms に十分間に合います

### 一連の流れの速さ（replay）

14 秒の会話を 100 ms ずつ実時間で流し、2 回目（モデルの準備の済んだ状態）を記録しました。区切りは無音 300 ms・最長 8 秒、
Whisper は base・日本語。`results/replay-*.json`。

| プラットフォーム | Whisper の実行 | audio_ctx を縮める | 1 発話の文字起こし (ms) | 結果までの遅れ・中央値 (s) | 最大 (s) | 音の終わりから全部出るまで (ms) | 発話の処理時間 / 音の長さ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| macOS | Metal | しない | 48–103 | 0.94 | 5.73 | 202 | 0.07 |
| macOS | Metal | する | 45–108 | 0.95 | 5.72 | 208 | 0.09 |
| Windows | CPU（AVX2） | する | 187–1063 | 1.22 | 5.90 | 1223 | 0.25 |
| Android | CPU | しない | 3790–4731 | 14.18 | 22.43 | 22454 | 2.39 |
| Android | CPU | する | 716–1273 | 4.57 | 6.79 | 4334 | 0.63 |
| iOS シミュレータ | CPU | する | 298–396 | 1.51 | 5.98 | 639 | 0.22 |
| web（Chrome、8 スレッド） | WebAssembly | する | 452–975 | 2.83 | 6.37 | 2134 | 0.45 |
| iPad Air 4 | Metal | する | 108–219 | 1.12 | 5.85 | 312 | — |

- 「結果までの遅れ」は、発話の音が終わってから、その結果が溜まるまで。最大の約 6 s は、最長 8 秒で切った区間の最初の発話
  （区間が終わるまで解析が始まらない）
- Android は、ONNX Runtime を 2 スレッドに絞っています（`ORT_THREADS=2`）。絞らない最初の測定では、2 回目に 1 発話 13〜66 s まで
  遅くなりました（Whisper と取り合ったか、熱。切り分けていない）
- 環境音（YAMNet ＋ CLAP、10 秒の窓）は、どのプラットフォームでも音の終わりから 0.03〜0.8 s で出ました

### 区切り方の比較（macOS）

| 区切り | 発話の数 | 遅れ (s) | 話者の割り当て |
| --- | --- | --- | --- |
| 無音 500 ms・上限なし（kiarina） | 6 | 4.6〜12.6 | 0,1,0,1,0,1（Python と同じ） |
| 無音 300 ms・最長 8 秒（アプリの既定） | 8 | 0.13〜5.73 | 0,1,2,0,1,0,1,1（「さっちは」を 3 人目に数えた） |

`results/replay-macos-kiarina-vad.json`・`results/replay-macos.json`。

### 文字起こしの例（macOS、base）

| 推定の正しい文 | base | base・audio_ctx を縮める |
| --- | --- | --- |
| もしもし、もう駅に着いた？ | もしもしもう息に吹いた? | もしもしもう息に吹いた? |
| うん、今改札出たところ。そっちは？ | うん 今 開殺していたところ そっちは? | 今開殺出れたところ 今開殺出れたところ ／ さっちは。 |
| 了解。じゃあ、カフェの前で待ってるね。 | 良い。じゃあ、カフェの前で待ってるね。 | 理解。じゃあ、カフェの前で待ってるね。 |

base は日本語の聞き違いが多く、medium はほぼ正しく書けました（`packages/whisper_cpp/README.md`。macOS の Metal で 14 秒が約 1 s）。
「推定の正しい文」は medium の出力と文脈から推したもので、人が聞いて確かめたものではありません。正解の文字起こしは用意していません。

### マイクの経路（web）

Chrome を `--use-fake-device-for-media-stream --use-file-for-fake-audio-capture=<wav>` で起動し、同じ音声をマイクとして流しました。
アプリはマイクの許可を求め、16 秒マイクを点け、消してから `recall` で取り出します（`results/mic-web-fake-device.json`）。
16.4 秒で 255,605 サンプル（16 kHz）が届き、発話 11 件と環境音 2 件が取り出せました。発話の内容は replay と同じですが、話者が
4 人（0〜3）に分かれました（Chrome がマイクの音を変えるため）。

- **Chrome のサンドボックスの中からは、偽のマイクの WAV が無音で届きました**（RMS 0）。`--no-sandbox` を付け、WAV を一時フォルダに
  置くと届きました。既定の偽のマイク（ビープ音）はサンドボックスのままでも届きます

### 本物のマイク（iPad Air 4）

`AUTO=mic`・`MIC_SECONDS=90`・Whisper small（`audio_ctx` は縮めない）。アプリがマイクの許可を求め、人が「許可」を押し、
モデルの準備の後にマイクが点いて 90 秒、人が iPad に向かって日本語で話しました（`results/mic-ipad-owner-speech.json`。
話した内容は公開しないので、文字数だけを残しています）。

| 項目 | 値 |
| --- | --- |
| マイクから届いたサンプル | 1,439,754（16 kHz で 89.98 s。90.54 s 点けていた） |
| 段ごとの処理時間 / 音の長さ | VAD 0.07、発話（話者変化＋ASR＋埋め込み）0.67、環境音 0.02。取りこぼし 0 |
| 発話 | 20 件。1 件の文字起こし 0.9〜1.5 s |
| 話者 | 9 人（0〜8）に分かれた。**実際に話したのは 1 人**（話した本人に確かめた）。大半の発話は話者 2 |
| Whisper の作り話 | 0.42〜0.67 s の区間 5 件が「ご視聴ありがとうございました!」（どれも話者の判定が無音・重なり） |
| 環境音（10 秒ごと 9 件） | Speech（0.33〜0.69）、Inside, small room、White noise、Typing など |

## Architecture

```text
packages/audio_analysis   解析（アプリにも ASR にも依存しない Dart のパッケージ）
  SileroVad → VoiceDetector → [queue] → SpeakerChangeDetector(pyannote) → Asr + Ecapa → SpeechEvent
  AudioWindowBuffer(10 s) → [queue] → YamnetTagger + ClapSoundEmbedder → AmbientEvent
  AudioAnalyzer（キューと統計）、HearingStore（1 時間・5000 件で古いものから消える）、ModelStore（ダウンロードと sha256）
packages/whisper_cpp      whisper.cpp v1.9.5：dart:ffi（macOS・iOS は Metal、Android・Windows は CPU）、web は WebAssembly
app/                      確認用のアプリ（許可・ダウンロード・マイク・recall・parity・replay）
tools/                    Python の基準データ（fixtures/）と YAMNet の変換
```

- ONNX Runtime は flutter_onnxruntime 1.9.0（ONNX Runtime 1.28）。web だけは、onnxruntime-web 1.30.0 を `dart:js_interop` で
  直接呼びます。flutter_onnxruntime の web 実装は int64 のテンソルを Dart の `Int64List` から作り、dart2js には `Int64List` が
  無いので、Silero VAD の `sr` を渡せないためです
- 推論は待ち行列で順に流します。VAD はマイクに追いつくよう別の段にし、話者の切り替わり・ASR・埋め込みはその後ろ、環境音はさらに
  別の段です。段が遅れたら、いちばん古いものを捨てて数えます（今回の測定では 0 件）
- モデルは元の配布元から sha256 を確かめてダウンロードします（`ModelCatalog`）。YAMNet の ONNX はどこにも公開していないので、
  アプリに同梱しています（`asset:` の URL）
- iOS は、flutter_onnxruntime が静的リンク（`use_frameworks! :linkage => :static`）を求めます。このとき whisper_cpp の C の
  関数がアプリに残らず、`transcribe` が返らなくなりました。podspec でリンカーに残すよう直しています（`packages/whisper_cpp/README.md`）

### Python との違い（意図したもの）

- YAMNet は窓全体を 0.975 秒ずつ見て平均する（kiarina は最初の 0.975 秒だけ）
- 発話に最長（`maxVoiceMs`）を付けられる（kiarina は上限なし）。アプリの既定は無音 300 ms・最長 8 秒（kiarina は 500 ms・上限なし）
- 話者ごとに覚える埋め込みは 32 個まで（kiarina は無限）
- 段ごとの待ち行列に上限がある

## Input

`tests/assets/mp3/conversation_2speaker_14s_16k.mp3`（labs の共有アセット）を 16 kHz・mono の WAV にしたもの（14.171 s、2 人の日本語の会話）。
作り方と sha256 は `tools/README.md`。

## How to run

```sh
mise run //:test-assets:download
mise run prepare                 # WAV・fixtures・YAMNet の ONNX をアプリへ
# Python の基準データと YAMNet の変換（済んでいれば不要）: tools/README.md
# whisper.cpp のソース: packages/whisper_cpp/tool/fetch_whisper_cpp.sh、web の wasm: packages/whisper_cpp/tool/build_web.sh
(cd packages/audio_analysis && flutter test)        # Python との一致（推論なし）

MODE=parity mise run macos                         # work/report-macos-parity.json
MODE=replay EXTRA_DEFINES="--dart-define=FIT_AUDIO_CTX=true" mise run macos
MODE=replay mise run android                       # adb でつないだ端末
WIN_HOST=<user@windows-pc> MODE=replay mise run windows
```

web と iOS シミュレータは手で:

```sh
(cd app && flutter build web --release --dart-define=AUTO=parity)
python3 packages/whisper_cpp/web/serve.py --root app/build/web --port 8790 --coi --coep credentialless &
node packages/whisper_cpp/web/harness/run_headless.mjs http://127.0.0.1:8790/

(cd app && flutter build ios --simulator --debug --dart-define=AUTO=replay --dart-define=AUTO_EXIT=true)
# simctl install / launch の後、アプリのデータの Library/Application Support/report-iOS.json を読む
```

アプリの設定は `--dart-define` で渡します: `AUTO`（`parity`・`replay`・`replay-fast`・`mic`）、`WHISPER_MODEL`（`tiny`・`base`・`small`・`medium` など）、
`FIT_AUDIO_CTX`、`ORT_THREADS`、`WHISPER_THREADS`、`MIN_SILENCE_MS`、`MAX_VOICE_MS`、`MIC_SECONDS`、`YAMNET_URL`。
レポートは 700 文字ずつ `HEARING_LAB_REPORT i/n` の行で出し（logcat は 1 行 1 KB で切れる）、`tools/join_report.py` で 1 つに戻します。

## Environment

- Flutter 3.47.2、flutter_onnxruntime 1.9.0、record 7.1.2、whisper.cpp v1.9.5、onnxruntime-web 1.30.0、Emscripten 6.0.12
- macOS: Apple M1 Max MacBook Pro 64 GB、macOS 27.0.1（profile ビルド）
- Windows: Core i9-12900K・64 GB、Windows 11、MSVC 14.38（profile ビルド）
- Android: Pixel 6（Android 17、profile ビルド、arm64）
- iOS: iPad Air 4（iPadOS 27.0.1、profile ビルド、Whisper は Metal）と iPhone 17 のシミュレータ（iOS 27.0、debug ビルド。Whisper は CPU）
- web: headless Chrome 155、同じ Mac。COOP/COEP（credentialless）付きで配信し、Whisper は 8 スレッド
- Python の基準: Python 3.12.10、onnxruntime 1.31.0、ai-edge-litert 2.3.0（`tools/README.md`）

## 確かめていないこと・制約

- **本物のマイクで人が話す確認は iPad だけ**（macOS・Windows・Android はまだ。許可の画面への応答が要る）
- **短い区間の作り話と、話者の分かれすぎへの対策**は入れていない（候補: 話者でない区間と 0.8 s 未満を ASR にかけない、Whisper の
  `no_speech_prob` で捨てる、短い発話では新しい話者を作らない、しきい値を上げ直す）。正解の話者の数での評価もしていない
- 入力は 14 秒の 1 本だけ。正解の文字起こし・話者の正解での評価はしていない
- 長時間の連続（メモリ・熱・待ち行列）、マイクの抜き差し・切り替え、他のアプリが鳴らす音
- Android の熱の影響（測定は続けて行った）、Android の 32 bit 端末（whisper_cpp は arm64 と x86_64 だけ）
- web は Chrome だけ（Safari・Firefox・スマートフォンのブラウザは未確認）。web のモデルはページを開き直すたびに取り直す（ブラウザの HTTP キャッシュ任せ）
- クラウドの ASR（OpenAI など）は作っていない（`Asr` の口だけ）
- YAMNet の ONNX は公開していない（配布するなら置き場所を決める）

## Licenses of the models

Silero VAD（MIT）、pyannote-segmentation-3.0（MIT。元のモデルは利用条件への同意が要る gated）、ECAPA-TDNN ONNX（MIT）、
CLAP（Apache-2.0、laion。Xenova の ONNX のモデルカードには記載がない）、YAMNet（Apache-2.0）、Whisper（MIT）、
whisper.cpp（MIT）。URL と sha256 は `fixtures/models.json`。いくつかの URL は動くブランチ（`master`・`main`）を指していて、
固定しているのは sha256 だけです。
