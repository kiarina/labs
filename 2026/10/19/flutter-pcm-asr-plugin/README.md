# 確定PCM区間を OS の音声認識で最終文字にする Flutter plugin を、OS ごとに成立させる

## 目的と事前評価

呼び出し側が持つ確定済みの PCM16 区間（16 kHz mono、数秒）を渡し、OS 標準の音声認識から最終結果だけを受け取る
Flutter plugin の候補（作業名 `pcm_asr`。公開名・所有 repo は未決定）を作り、macOS・iOS・Windows・Android・Web
それぞれで「外部 PCM を受ける／結果が要求ごとに確定する／端末内で処理する／日本語が使える」を実測で確かめる。
マイクは plugin が開かない。record・VAD・SCD・話者 ID は呼び出し側が所有する。

先行 lab [apple-speech-scd-asr](../apple-speech-scd-asr/README.md) で Mac の SpeechAnalyzer が成立したことを出発点にし、
同じ共有素材の 6 区間（SCD 確定済み、正解文つき）を同じ 3 パス（正順 2 回・逆順 1 回）で流す。
事前目安は、非空の結果 18/18、要求 ID の一致 18/18、正規化 CER 10 % 以下、準備後の確定待ちの p95 が 1 秒以内。
少数の共有素材の目安で、製品合格や一般的な精度比較ではない。

pub.dev の既存パッケージはどれも外部 PCM を受けない（[research/pub-packages.md](research/pub-packages.md)）。
OS ごとの API の調査は [research/apple.md](research/apple.md)・[research/android.md](research/android.md)・
[research/windows.md](research/windows.md)・[research/web.md](research/web.md)。

## 条件と再現

- Apple M1 Max、macOS 27.0.1、Xcode 27.1、Flutter 3.47.2 / Dart 3.13.2。iOS は iPad Air（第 4 世代、A14）、iOS 27.0.1。
  Web は Google Chrome 155（ブランド版。Chromium 単体は Google の音声サービスに届かない）。
  Windows は Core i9-12900K、Windows 11 25H2（build 26220）、日本語ロケール。Android は Pixel 6（Android 17、build CP2A.260705.006、
  Android System Intelligence の `AiAiSpeechRecognitionService`、debug build）。
- 共有素材 `tests/assets/mp3/conversation_2speaker_14s_16k.mp3` を 16 kHz mono PCM16 に decode し、`fixtures/scd.json` の
  境界で 6 区間に切る（`tools/prepare.py`。切り出しの hash は `fixtures/segments.json`）。例題アプリは区間を raw PCM の
  asset として読み、plugin に 3 パス渡して `PCM_ASR {json}` の行を出す。`tools/evaluate.py` が正規化 CER
  （NFKC・小文字化・空白と句読点の除去）・ID 一致・要求→確定の時間・異常系 3 件（未対応 locale、cancel、無音）を検算する。
- 要求→確定の時間は、PCM を plugin に渡してから最終結果を受け取るまで（MethodChannel を含む）。モデルの準備は別計測。

```sh
mise -C 2026/10/19/flutter-pcm-asr-plugin run macos            # build → ヘッドレス実行 → 検算
DEVICE=<ios device id> mise -C 2026/10/19/flutter-pcm-asr-plugin run ios
mise -C 2026/10/19/flutter-pcm-asr-plugin run web              # Chrome を puppeteer-core で起動（tools/web）
ANDROID_SERIAL=<adb id> mise -C 2026/10/19/flutter-pcm-asr-plugin run android
mise -C 2026/10/19/flutter-pcm-asr-plugin run                  # 保存済み結果の検算と Dart の analyze / test だけ
```

Windows は plugin を作らず、`tools/windows/` の PowerShell と C++（MSVC、ATL 不要）で OS の認識器を直接確かめた。

## 結果

| 環境 | エンジン | 端末内 | 結果 | CER | 要求→確定 中央値 / p95 / 最初 |
| --- | --- | --- | --- | ---: | --- |
| macOS 27 | Apple SpeechAnalyzer（plugin 経由） | はい | 18/18、ID 一致 18/18、異常系 3/3 | **0 %** | **99 / 105 / 154 ms** |
| iOS 27（iPad Air 4） | 同上（同じ `darwin/` のソース） | はい | 18/18、ID 一致 18/18、異常系 3/3 | **0 %** | **117 / 140 / 554 ms** |
| Web（Chrome 155） | `SpeechRecognition.start(track)`、cloud | いいえ | 18/18、ID 一致 18/18、cancel・無音は通過、未対応 locale は検出不能 | 5.8 %（うち 3 字は「本当／ほんと」の表記） | 3444 / 3895 / 2910 ms（区間長＋前後の無音 1 秒） |
| Windows 11 25H2 | SAPI desktop（MS-1041-80-DESK） | はい | 18/18 返るが 1〜2 文字ずつ | 97 % | 18 ms（意味なし） |
| Windows 11 25H2 | OneCore DNN ja-JP（SAPI 経由） | – | `LoadDictation` が `SPERR_NOT_FOUND`。認識できない | – | – |
| Android 17（Pixel 6） | `SpeechRecognizer` + `EXTRA_AUDIO_SOURCE`（pipe、端末内の認識器） | はい | 18/18、ID 一致 18/18、異常系 3/3 | 4.7 %（「助かる→助かり」と「本当／ほんと」） | **458 / 674 / 798 ms**（待たずに書く）。実時間で書くと 3311 / 3719 / 2621 ms |

証拠: `results/macos.json`・`results/ios.json`・`results/android.json`・`results/android-pace-1.0.json`・`results/web.json`（`pass` と区間ごとの文字・時間）、
`results/windows/`（probe のログ）。
Web の `prepare` は何もしない（Chrome の端末内モデルは約 60 MB の download と確認が要り、アプリの判断にする）。

### 読み方

- **Apple は macOS と iOS で同じ Swift が同じ契約で動いた。** iPad Air 4（A14）でも `SpeechTranscriber.isAvailable` は真で、
  日本語モデルは OS 側に入っていた（`prepare` 132 ms、download なし）。最初の要求だけ 554 ms。
  `support()` の `model_state` は、アプリがまだ locale を reserve していないと installed でも `downloadable` と出る
  （`AssetInventory.status` の仕様。`prepare` で解消する）。
- **Web は「成立するが端末内ではない」。** ブランド版の desktop Chrome/Edge 135 以降だけ。track が終わっても確定しないので、
  無音の尾を 0.7 秒再生してから `stop()` を呼ぶ（呼ばないと確定が来ない。直後に呼ぶと末尾の語が落ちた）。
  `continuous=false` だと区間内の休止で最初の句だけになったので `continuous=true` で全結果を結合する。
  先頭の「うん」は 0.3 秒の無音を前に置いても落ちた。音声は Google のサーバーへ送られる（`on_device: false`）。
  未対応 locale は cloud が何でも受けるので事前に弾けない（`known_limits` として記録）。Chrome Android・Safari・Firefox は track 入力がない。
- **Windows は OS の認識器では成立しない。** 入っている ja-JP の認識器は 2 つあるが、古い desktop 認識器は日本語の dictation に
  使えず（1〜2 文字しか返さない）、新しい OneCore DNN は SAPI から辞書を読めない。`Windows.Media.SpeechRecognition` はマイク専用、
  Windows AI の Speech は英語のみ・experimental・MSIX の identity が要る（[research/windows.md](research/windows.md)）。
  Windows の日本語は whisper.cpp などの非 OS backend になる。
- **Android は Pixel 6 で端末内・日本語・`RECORD_AUDIO` なしで成立した。** 日本語の端末内モデルは入っていた（`checkRecognitionSupport` が
  installed、`prepare` 50 ms）。service は要求ごとに "Create input stream from external audio PFD" を記録する。
  **実時間で書く必要はなかった**: 待たずに書いても文字は同じで、要求→確定が 3.3 秒から 0.46 秒に縮んだ（field report と
  ML Kit の文書は実時間を求めている。他の端末・認識サービスでは要確認で、`PACE` で戻せる）。pipe を閉じた直後に終えると末尾の
  1〜2 音節が落ちたので、無音 0.6 秒を書いてから閉じる。service が pipe を開く前（`onReadyForSpeech` の前）に閉じると
  セッションが終わらないので、writer は ready を待つ。locale 不正などで service が読まない pipe に書く writer は詰まるので、
  要求ごとに thread を分け、終わった要求は両端を閉じて writer を解く（1 本の executor で直列にしていたときは後続の要求が 20 秒待った）。
  `stopListening` は呼ばず、cancel の後は recognizer を作り直す。無音 1 秒は service が `ERROR_NO_MATCH` を 0.3 秒で返し、空文字にする。

## 体験版（demo/）

Mac で評価してもらった体験アプリ（record → VAD → 逐次 SCD → 話者 ID → ASR）を `demo/` に写し、ASR を plugin に差し替えて
iOS・Android・Web・macOS で動かした。操作と作りは [demo/README.md](demo/README.md)。`mise run demo-ios|demo-android|demo-web|demo-macos`。

| 環境 | 共有音声（14 秒・6 発話）の通し | ASR（要求→確定） | 音声区間末尾→表示 |
| --- | --- | --- | --- |
| macOS 27 | 6 区間・2 話者、誤り 0（`results/demo-macos.json`） | 101〜260 ms | 0.9〜1.1 秒（逐次 SCD の確定待ち込み） |
| iOS 27（iPad Air 4） | 準備完了まで確認（profile build を入れた） | – | – |
| Android 17（Pixel 6） | 6 区間・2 話者（`results/demo-pixel6.png`） | 平均 557 ms | 0.6〜1.6 秒 |
| Web（Chrome 155、cloud） | 6 区間・2 話者（`results/demo-web.json`） | 3.0〜3.9 秒 | 4〜11 秒（ASR が区間長ぶん掛かり、直列の要求が溜まる） |

- Android の release build は onnxruntime を R8 から守らないと JNI が `SIGABRT` で落ちる（`demo/android/app/proguard-rules.pro`）。
  10/18 の lab と同じ対処。
- flutter_onnxruntime 1.9.0 は iOS 16・macOS 14 以上を要る（demo の deployment target を上げた）。
- Web はブランド版 Chrome で `localhost` か https から開く（マイクの取得条件）。モデル 88 MB をページの読み込み時に取る。
  cloud の ASR は区間長ぶん待つので、連続した会話では表示が遅れていく。
- 実マイクでの評価はオーナーに依頼中。人数・時間・内容は未記録。

## 判断と限界

**外部 PCM → OS 標準 ASR → 要求ごとの最終結果、という契約は Apple（macOS・iOS）と Android（Pixel 6）で端末内で成立し、
Web は cloud 前提で成立、Windows は不成立。** 5 環境で同じ API・端末内・日本語を保証する plugin は作れない。公開するなら、
対応表を `support()` の各フィールドで正直に返し、Windows（と端末内が要る Web）は別 backend に委ねる形になる。

- 14 秒・6 発話の日本語だけ。長文・雑音・固有名詞・実マイク・同時発話・長時間・同時要求は未確認。
- Apple の cancel は要求が約 100 ms で終わるため、検証では cancel が間に合わず「cancel 前に完了」で通過している。
  Web では cancel が効いた。Apple の cancel の実効は長い区間で別に確かめる。
- iOS は 1 機種・profile build。Apple Intelligence 非対応の古い機種（A13 以前）は `isAvailable` が偽になると報告がある。
- Android は Pixel 6・Google の端末内認識器・debug build の 1 条件。他社端末や端末内認識器の無い端末、cloud の既定認識器に
  `EXTRA_AUDIO_SOURCE` を渡したときの挙動（マイクに黙って切り替わる可能性）は未確認。
- Web の時間は Chrome の cloud の応答を含み、回線で変わる。
- `pcm_asr` の名前・所有 repo・publisher・ライセンス（lab は MIT）・初期公開の範囲は未決定。

## 参照

- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)、
  [Asking Permission to Use Speech Recognition](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)（SpeechAnalyzer は音声を送らない）
- [RecognizerIntent.EXTRA_AUDIO_SOURCE](https://developer.android.com/reference/android/speech/RecognizerIntent#EXTRA_AUDIO_SOURCE)、
  [goofmint/offline_stt](https://github.com/goofmint/offline_stt)（Pixel 6 の field report）
- [Web Speech API editor's draft](https://webaudio.github.io/web-speech-api/)、
  [Chrome: MediaStreamTrack support](https://chromestatus.com/feature/5178378197139456)、[On-device Web Speech API](https://chromestatus.com/feature/6090916291674112)
- [Windows AI Speech recognition](https://learn.microsoft.com/en-us/windows/ai/apis/speech-recognition)、
  [Windows.Media.SpeechRecognition の package identity 要件](https://learn.microsoft.com/en-us/windows/apps/develop/input/speech-recognition)

Web の最初の 2 回は `bool.fromEnvironment` が `1` を真と読まない・`start.length` で機能を判定した実装ミスで 1 行も出ず、直して測った。
認識条件の変更ではない。
