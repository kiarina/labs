# Tapping video frames and audio PCM from flutter_webrtc tracks on five platforms

flutter_webrtc 1.6 には、映像のフレームと音声の PCM を Dart へ継続的に渡す API がありません。この lab では、
flutter_webrtc を改造せずに、別の Flutter plugin（`media_taps/`）から flutter_webrtc が持つネイティブのトラックに
受け口（sink / renderer）をつなぎ、**ローカル（カメラ・マイク）とリモート（WebRTC で受けたトラック）の両方**から
フレームと PCM を毎回受け取れるかを、Web / macOS / iOS / Android / Windows で確かめました。

前提となる lab: [Flutter realtime media pipeline](../flutter-realtime-media-pipeline/README.md)（Pure Dart の Pipeline と、
getStats のポーリングでしか中身を観測できなかったことの記録）。

## Purpose

1. flutter_webrtc 1.6.2+hotfix.3 を fork せずに、別の plugin からネイティブのトラックを取り出し、受け口をつなげるか
2. ローカルのカメラ・マイク、リモートの映像・音声のそれぞれで、フレームと PCM が**毎回**届くか（1 秒あたりの回数、形式、解像度、
   サンプルレート、音の大きさ）
3. 縮小した輝度（Y 面）とフル解像度の輝度、PCM を Dart まで届けたとき、どの程度の量と時間がかかるか
4. **送信先の無い状態（getUserMedia だけ）でもマイクの PCM が届くか**（前の調査で Windows は届かないと予想した）

各条件で 12 秒動かし、最初の 2 秒を除いた 10 秒を集計しました。Dart は 50 ms ごとに plugin を poll し、届いた輝度と
PCM の全バイトに触れます（輝度の平均と RMS の計算。本番の処理の代わり）。

## Answer

- **5 つのプラットフォームすべてで、fork せずに取れました。** ネイティブ 4 つは flutter_webrtc が外向きに公開している
  入口（Android と iOS/macOS の `sharedSingleton`、Windows の `FlutterWebRTCPluginSharedInstance()`）からトラックを
  取り出し、Web はトラックの下にあるブラウザの MediaStreamTrack を使います
- **映像はローカルもリモートも、カメラが出したフレームが毎回届き、Dart まで落とさずに渡せました**（Web 20 fps、
  macOS 26 fps、iPad 60 fps、Pixel Fold 25〜29 fps、Windows 30 fps）
- **音声は 10 ms ごと（1 秒に 100 回）に PCM が届きました。** Web・macOS・iOS・Android は 48 kHz、Windows は 16 kHz でした
- **送信先の無いマイクは、Android と Web だけが届きました。** macOS・iOS・Windows は、flutter_webrtc の
  `startLocalRecording` を呼んでも（Windows には実装自体が無い）、音声を送る PeerConnection が無い間は 1 回も届きません。
  **音声だけの loopback PeerConnection を張ると、3 つとも届きました**
- フル解像度の輝度を毎フレーム Dart に渡すのも可能でした（Windows 26 MB/秒、Pixel Fold 23 MB/秒、iPad 18.5 MB/秒）。
  ただし Pixel Fold では poll 1 回が 18 ms、Dart 側の処理が 39 ms（中央値）かかり、縮小（320 幅）する場合の約 13 倍でした

## Architecture

```text
app/（テスト用アプリ）
  getUserMedia ─┬─ ローカルのトラック ───────────────┐
                └─ loopback PeerConnection（A→B）─ リモートのトラック ─┐
                                                        │             │
media_taps/（Flutter plugin）  attach(track) ───────────┴─────────────┘
  Android  FlutterWebRTCPlugin.sharedSingleton.getLocalTrack / getRemoteTrack
           映像: VideoTrack.addSink        マイク: LocalAudioTrack.addSink       受信音声: AudioTrack.addSink
  iOS/mac  FlutterWebRTCPlugin.sharedSingleton().localTracks / remoteTrack(forId:)
           映像: RTCVideoTrack.add(renderer) マイク: LocalAudioTrack.addProcessing  受信音声: RTCAudioTrack.add(renderer)
  Windows  FlutterWebRTCPluginSharedInstance()->MediaTrackForId（仮想関数）
           映像: RTCVideoTrack::AddRenderer  マイク・受信音声: RTCAudioTrack::AddSink
  Web      MediaStreamTrackWeb.jsTrack
           映像: MediaStreamTrackProcessor   音声: AudioWorklet（Blob URL で読み込み）
      ↓ 受け口は数え、縮小・変換し、上限付きのキューに積む（映像 8 フレーム、音声 96 KB）
  Dart ← poll()（MethodChannel。Web は Dart のまま）
```

- ネイティブの受け口は WebRTC の取り込み・デコード・音声のスレッドで呼ばれます。受け口の中では、数える・縮小して I420 に
  変換する・Y 面をコピーする、までを行い、Dart へはキュー経由で渡します
- 変換の方法はプラットフォームで違います。Android は `cropAndScale` してから `toI420`（GPU のテクスチャを縮めてから読み出す）、
  iOS/macOS は `cropAndScale` してから `toI420`（libyuv）、Windows は `DataY()` の I420 から間引き、Web は `VideoFrame.copyTo`
  してから Dart で間引きます
- loopback PeerConnection は CPU 過負荷検知を切っています（前の lab の追加実験。解像度が下がらないように）
- Dart と plugin の間は、全プラットフォーム共通で poll（50 ms ごと）にしました。Windows の EventChannel はプラットフォーム
  スレッドからしか送れず、スレッドの受け渡しが要るためです

### plugin から flutter_webrtc へのつなぎ方

| | 依存の宣言 | 注意点 |
| --- | --- | --- |
| Android | `compileOnly(project(":flutter_webrtc"))`、`compileOnly("io.github.webrtc-sdk:android:150.7871.01")` | リモートのトラックは `getRemoteTrack`（ストリーム付きで届いたもの）で取る。transceiver 経由の wrapper は `getTransceivers()` で dispose され、受け口が外れる |
| iOS / macOS | Swift Package で `.package(name: "flutter_webrtc", path: "../flutter_webrtc-1.6.2+hotfix.3")` に依存し、`flutter-webrtc` と `WebRTC` の product を使う（Flutter が生成する package と同じ書き方） | ローカルの音声トラックに renderer をつないでも何も来ない。マイクは `addProcessing`（エコー除去後、アプリ全体で 1 本） |
| Windows | CMake で `flutter_webrtc_plugin` と `libwebrtc.dll.lib` にリンクし、`LIB_WEBRTC_API_DLL`・`RTC_DESKTOP_DEVICE` を同じく定義 | flutter_webrtc の class の配置に依存する（版を変えたら再ビルド必須）。`MediaTrackForId` は lock を取らないのでプラットフォームスレッドで呼ぶ |
| Web | `dart_webrtc` の `MediaStreamTrackWeb` を import | 受信した音声は、`<audio>` で再生していないと WebAudio に無音で届く（plugin で muted の要素を付けている） |

## Results

実行環境: Web は Chrome 153 headless（fake のカメラ・マイク）、macOS は MacBook Pro M1 Max（内蔵カメラ、macOS 26.6.2）、
iOS は iPad Air 第 4 世代（iPadOS 26.6.2）、Android は Pixel Fold（Android 17）、Windows は Windows 11 のデスクトップ PC
（USB カメラ）。Flutter 3.47.2、flutter_webrtc 1.6.2+hotfix.3、すべて release ビルド。

- `local`: getUserMedia だけ（Android・iOS・macOS は `NativeAudioManagement.startLocalRecording()` も呼ぶ）
- `loopback`: 同じアプリの中で PeerConnection A → B に映像と音声を送り、B で受けたトラックにも受け口をつなぐ
- `audio-loopback`: A → B に音声だけを送る
- `loopback-full`: `loopback` で、映像を縮小せずフル解像度の輝度を Dart に渡す（それ以外は 320 幅に縮小）

表の各セルは「受け口が呼ばれた回数/秒・形式」と「Dart が受け取った量/秒」、最後の列は poll 1 回の往復時間と、Dart が
届いたデータに触れた時間（どちらも中央値、ms）です。数値は `results/<platform>-<scenario>.json`。

| プラットフォーム | 条件 | ローカル映像 | マイク | リモート映像 | リモート音声 | poll / Dart (ms) |
| --- | --- | --- | --- | --- | --- | --- |
| Web | local | 20 fps 1280×720 (NV12) 変換 0.79 ms / Dart 20 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | — | — | 0.1 / 0.4 |
| Web | loopback | 20 fps 1280×720 (NV12) 変換 0.63 ms / Dart 20 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | 20 fps 480×270 (I420) 変換 0.50 ms / Dart 20 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | 0.1 / 0.6 |
| Web | audio-loopback | 20 fps 1280×720 (NV12) 変換 0.81 ms / Dart 20 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | — | 100/s 48 kHz ×1 / Dart 48.3 k/s | 0.1 / 0.4 |
| Web | loopback-full | 20 fps 1280×720 (NV12) 変換 5.78 ms / Dart 20 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 20 fps 640×360 (I420) 変換 0.77 ms / Dart 20 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 0.1 / 4.4 |
| macOS | local | 26 fps 640×480 (CVPixelBuffer 420v) 変換 0.19 ms / Dart 26 fps | **届かない** | — | — | 0.5 / 0.8 |
| macOS | loopback | 26 fps 640×480 (420v) 変換 0.19 ms / Dart 26 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | 26 fps 640×480 (420f) 変換 0.17 ms / Dart 26 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | 0.5 / 1.6 |
| macOS | audio-loopback | 26 fps 640×480 (420v) 変換 0.16 ms / Dart 26 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | — | 100/s 48 kHz ×1 / Dart 48.3 k/s | 0.6 / 0.8 |
| macOS | loopback-full | 26 fps 640×480 (420v) 変換 0.17 ms / Dart 26 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 26 fps 640×480 (420f) 変換 0.09 ms / Dart 26 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 0.8 / 7.3 |
| iOS | local | 60 fps 640×480 (420v) 変換 0.20 ms / Dart 60 fps | **届かない** | — | — | 0.5 / 2.6 |
| iOS | loopback | 60 fps 640×480 (420v) 変換 0.20 ms / Dart 60 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 60 fps 640×480 (420f) 変換 0.17 ms / Dart 60 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 0.8 / 5.1 |
| iOS | audio-loopback | 60 fps 640×480 (420v) 変換 0.18 ms / Dart 60 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | — | 100/s 48 kHz ×1 / Dart 48.2 k/s | 0.6 / 2.2 |
| iOS | loopback-full | 60 fps 640×480 (420v) 変換 0.15 ms / Dart 60 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | 60 fps 640×480 (420f) 変換 0.13 ms / Dart 60 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 1.3 / 16.0 |
| Android | local | 29 fps 1280×720 (OES テクスチャ) 変換 3.22 ms / Dart 29 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | — | — | 1.5 / 1.5 |
| Android | loopback | 25 fps 1280×720 (OES) 変換 4.60 ms / Dart 25 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | 25 fps 1280×720 (OES) 変換 6.60 ms / Dart 25 fps | 100/s 48 kHz ×1 / Dart 48.2 k/s | 2.1 / 2.9 |
| Android | audio-loopback | 25 fps 1280×720 (OES) 変換 3.28 ms / Dart 25 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | — | 100/s 48 kHz ×1 / Dart 48.3 k/s | 1.6 / 1.5 |
| Android | loopback-full | 25 fps 1280×720 (OES) 変換 5.54 ms / Dart 25 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 25 fps 1280×720 (OES) 変換 6.26 ms / Dart 25 fps | 100/s 48 kHz ×1 / Dart 48.3 k/s | 18.4 / 38.5 |
| Windows | local | 30 fps 1280×720 (I420) 変換 0.09 ms / Dart 30 fps | **届かない** | — | — | 0.2 / 0.2 |
| Windows | loopback | 30 fps 1280×720 (I420) 変換 0.08 ms / Dart 30 fps | 100/s 16 kHz ×1 / Dart 16.1 k/s | 30 fps 1280×720 (I420) 変換 0.08 ms / Dart 30 fps | 100/s 16 kHz ×1 / Dart 16.1 k/s | 0.3 / 0.5 |
| Windows | audio-loopback | 30 fps 1280×720 (I420) 変換 0.08 ms / Dart 30 fps | 100/s 16 kHz ×1 / Dart 16.1 k/s | — | 100/s 16 kHz ×1 / Dart 16.1 k/s | 0.2 / 0.2 |
| Windows | loopback-full | 29 fps 1280×720 (I420) 変換 1.30 ms / Dart 29 fps | 100/s 16 kHz ×1 / Dart 16.1 k/s | 29 fps 1280×720 (I420) 変換 1.33 ms / Dart 29 fps | 100/s 16 kHz ×1 / Dart 16.1 k/s | 7.2 / 8.3 |

どの条件でも、上限付きキューで Dart へ渡す前に捨てたフレームと PCM は 0 でした（`droppedToDart` が無い）。
ネイティブで計算した RMS と Dart で計算した RMS は、同じ条件で一致しました（マイクと受信音声が本物の信号であることの確認）。

### 観測した事実

- **フレームの形式はプラットフォームごとに違います。** Android はカメラも受信も OES テクスチャ（GPU 上）、iOS/macOS は
  カメラが `CVPixelBuffer` の 420v（video range）、受信が 420f（full range）、Windows は I420、Web はカメラが NV12、
  受信が I420 でした。回転は Android が 270°、iPad が 90°、ほかは 0°（バッファは回転していない）
- **Android の読み出しは重いです。** 320 幅に縮めてからでも 1 フレーム 3〜7 ms かかりました（GPU から CPU へのコピー。
  取り込みのスレッドで実行している）。ほかのネイティブは 0.1〜0.2 ms でした
- **送信先の無いマイク:**
  - Android は、flutter_webrtc の `LocalAudioTrack` が録音の生データ（エコー除去の前）を受け口へ配るので、
    `startLocalRecording` の後は送信なしでも届きました
  - macOS と iOS は `startLocalRecording` が成功しても届きません。受け口が音声処理（エコー除去など）の後のフックに
    あり、送信する音声が無いとその処理が走らないと解釈しています（未確認）
  - Windows は `startLocalRecording` が未実装（`MissingPluginException`）で、wrapper は送信中のストリームが無いと
    音をローカルの送り元に回しません（前の調査）
  - 3 つとも、音声だけを送る loopback を張ると届きました
- **Windows の音声は 16 kHz でした。** 他の 4 つは 48 kHz です。WebRTC の送信処理の内部レートと推定しています（未確認）
- **フル解像度の輝度を Dart へ渡す負荷**は、poll 1 回あたり Pixel Fold 18 ms / Dart 39 ms、iPad 1.3 ms / 16 ms、
  Windows 7 ms / 8 ms でした。320 幅なら、どれも数 ms 以下です
- Web のリモート映像は 480×270〜640×360 でした。dart_webrtc は CPU 過負荷検知の設定を渡さないので、Chrome のエンコーダーが
  入力を縮めています（ローカルのトラックは 1280×720 のまま）
- Android の端末の画面が消えていると、カメラが止まり映像の受け口は 1 回も呼ばれませんでした（最初の試行で起きた。
  画面を点けて取り直した値を載せています）

## Requirements and run

- Flutter 3.47.2（`.mise.toml`）。Windows は Visual Studio 2022 の「C++ によるデスクトップ開発」。
  日本語ロケールの Windows では `app/windows/CMakeLists.txt` の `/utf-8` が必要（flutter_webrtc の C++ が C4819 で止まる）
- iOS と macOS は Swift Package Manager（Flutter 3.47 の既定）で動かします。plugin に podspec は置いていません

```sh
mise run                # plugin と app の analyze、Web の build
mise run web-autorun    # headless Chrome で 4 条件を実行し results/web-*.json を書く
mise run macos-autorun  # macOS の実カメラ・マイクで 4 条件を実行（初回は権限の確認が出る）
```

ほかのプラットフォームは、次の方法で `scenario`・`seconds`・`convert`・`deliver`・`startrecording`・`exit` を渡します。
結果は `TAPS_RESULT {json}` の 1 行と、一時ディレクトリの `taps_result.json` に出ます。

| プラットフォーム | 渡し方 | 結果の受け取り方 |
| --- | --- | --- |
| Windows / macOS | 環境変数 `TAPS_SCENARIO` など | Windows は `%TEMP%\taps_result.json`（GUI アプリなので対話セッションで起動する） |
| iOS | `devicectl device copy to` でアプリの `tmp/taps_config.json` に置く | `devicectl device copy from` で `tmp/taps_result.json` |
| Android | `adb shell am start -n com.kiarina.labs.media_taps_app/.MainActivity --es scenario loopback ...`（`MainActivity` が `TAPS_*` 環境変数に写す）。カメラとマイクは `pm grant` で付与 | logcat の `TAPS_PART i/n`（1 行 1 KB で切れるため分割） |

## 未確認の事項と制約

- 各条件 1 回ずつ、10 秒の計測です。ばらつきは測っていません。Pixel Fold の fps（25〜29）は部屋の明るさで変わった可能性があります
- iOS / macOS の内蔵カメラは 640×480 しか出していません。1280×720 以上のカメラでの変換コストは未確認です
- Android は Pixel Fold の 1 台だけ、iOS は iPad の 1 台だけ、Web は Chrome だけです（Safari は MediaStreamTrackProcessor を
  Worker でしか使えない見込み、Firefox は使えない見込みで、どちらも未確認）
- macOS / iOS で送信なしのマイクが届かない理由は、ソースからの推定です
- 受け口の中では縮小と変換だけを行い、実際の画像処理・音声処理（推論など）は載せていません。Dart の処理は全バイトを 1 回読むだけです
- iOS / macOS のマイクはアプリ全体で 1 本の音声処理フックなので、LiveKit など同じフックを使うライブラリと併用すると競合します
- Windows の plugin は flutter_webrtc の class の配置に依存します。flutter_webrtc を上げたら plugin も再ビルドが必要です
- 長時間の実行、バックグラウンド化、デバイスの切り替え、renegotiation（受信トラックの wrapper が替わる）は試していません
