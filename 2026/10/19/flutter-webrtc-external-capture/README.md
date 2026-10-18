# Always-on camera and record capture into on-demand WebRTC media tracks

`camera` / `camera_desktop` と `record` の取得を一度だけ開始し、同じ映像と PCM を
必要な間だけ `flutter_webrtc` の通常のメディアトラックへ渡す実験です。
送信先や会話の終了に合わせてカメラ・マイクを開き直す必要があるかを調べます。

## 現在の結論

macOS、Android、iOS の実機と Chrome の仮想デバイスで、取得を維持したまま
待機 → 送信 → 待機 → 送信 → 待機を通せました。受信側の復号済み画像・非ゼロ PCM と
RTP 統計の両方を確認しています。Windows も外部から注入した映像と PCM を独立した Chrome で受信できました。
ただし、Windows の実カメラと WebRTC 側の追加マイク取得抑止は未検証・未対応です。
[Windows notes](windows-notes.md) に原因と必要な拡張を記録しています。

標準の Dart `Stream` を `MediaStream` として渡せるわけではありません。
ネイティブの外部入力ブリッジが必要で、Android では lab 内の `flutter_webrtc` コピーに
初期化フックを適用しています。pub cache は変更しません。

```text
camera / camera_desktop / Web camera adapter ─ BGRA ─┬─ 取得側の観測・解析
                                                     └─ gate ─ custom video source ─ video track
record.startStream ─ PCM16 / 48 kHz / mono ───────────┬─ 取得側の観測・解析
                                                     └─ gate ─ custom audio input ─ audio track
                                                                                      ↓
                                                                           flutter_webrtc PeerConnection
```

gate は待機中には入力を注入せず、取得側の callback は動かしたままにします。
送信境界で未送信の PCM を `flush()` します。共通アプリは送信ごとに PeerConnection を作り直し、
元の取得と出力トラックは維持します。Web の別試験では同じ接続での `replaceTrack(null)` と復帰も確認します。

## 検証方法

実行前の問いは「取得を開き直さず、同じデータから作った本物の映像・音声トラックを
必要時だけ送信し、次の送信にも復帰できるか」です。

- 待機 3 秒 → 送信 6 秒 → 待機 3 秒 → 送信 6 秒 → 待機 3 秒。
  接続準備や poll の処理時間は別にかかります。各条件 1 回の短時間試験です。
- ネットワークはアプリ内の PeerConnection ペア、host ICE のみ。外部 API・STUN・TURN は使いません。
- 取得 callback の回数・PCM バイト数、注入量、受信 track の画像・PCM、RTP の復号統計、
  取得 callback の最大間隔を記録します。映像内容や録音そのものは結果ファイルに保存しません。
- 合成入力は 320×240 の変化する色と 440 Hz / 48 kHz / mono / PCM16。
  実入力とは分け、ブリッジが無音を送っていないかを確認します。
- アプリ内の `pass` に加え、`tools/verify_results.py` で実測結果を検算します。
  各区間の映像 5 fps 以上、PCM は公称の 70% 以上、全区間の最大 callback 間隔 500 ms 以下、
  待機中の注入ゼロ、受信 PCM の非ゼロ RMS、RTP の受信・復号 sample/frame が条件です。
  無音 callback や送信側の誤観測だけでは合格にしません。

## 検証環境と結果

Flutter 3.47.2 / Dart 3.13.2、flutter_webrtc 1.6.2+hotfix.4、record 7.1.2、
camera 0.12.1、camera_desktop 2.0.0、dart_webrtc 1.8.2。解決した transitive dependencies は `app/pubspec.lock` に固定しています。
カメラのネイティブ出力はこの実験では 320 幅の BGRA に縮小し、Web は 640×480 / 15 fps です。

| 対象・入力 | 受信映像（1回目 / 2回目） | 受信 PCM RMS（1回目 / 2回目） | 最大取得間隔 音声 / 映像 | 判定 |
| --- | --- | --- | --- | --- |
| macOS 27.0.1 / M1 Max laptop、実デバイス | 180 / 181 frames | 0.0047 / 0.0090 | 118.7 / 57.2 ms | [PASS](results/macos-real.json) |
| Android 17 / Pixel 6、実デバイス | 183 / 183 frames | 0.1486 / 0.1899 | 161.2 / 242.4 ms | [PASS](results/android-real.json) |
| iPadOS 27.0.1 / iPad Air 4、実デバイス | 144 / 144 frames | 0.0094 / 0.0056 | 125.4 / 50.1 ms | [PASS](results/ios-real.json) |
| Chrome 155 / macOS、仮想デバイス | 89 / 90 frames | 0.0984 / 0.0961 | 60.2 / 75.1 ms | [PASS](results/web-flutter-capture.json) |
| Windows 11 / x64 → Chrome、合成入力 | 150 / 150 frames | 最大 RMS 0.1727 / 0.1733 | 22 / 42 ms | [入力・送信 PASS](results/windows-browser-synthetic.json) |
| Windows 11 / x64 → Chrome、実マイク＋合成映像 | 150 / 148 frames | 最大 RMS 0.0410 / 0.0392 | 49 / 42 ms | [入力・送信 PASS](results/windows-browser-record-profile-cleanup.json) |

受信 fps は 6 秒の送信区間で得られたフレーム数が基準で、厳密なレイテンシ測定ではありません。
`results/*synthetic*.json` は合成入力の補助試験です。最終の flush 追加前の補助結果も保存し、
最終構成の判定には上表の実取得結果を使います。Windows の映像は合成入力で、実カメラの確認にはなりません。失敗した条件・無効な測定も削除せず保存します。

## 実装の入口

- `app/lib/main.dart`: 取得・gate・PeerConnection・受信観測を組み合わせた自動試験。
- `app/lib/native_bridge.dart` / `web_bridge.dart`: `create()`、`pushVideo(...)`、
  `pushAudio(...)`、`flush()`、`dispose()`。
- `external_capture/`: macOS / iOS / Windows の外部入力 plugin。
- `patches/android/`: Android の再現可能な初期化フックと実装。
- `media_taps/`: 受信した画像と PCM を検証する、この lab 内で完結したコピー。
  [先行実験](../../../09/25/flutter-webrtc-media-taps/README.md)から適応しています。

| 対象 | 映像 | 音声 |
| --- | --- | --- |
| macOS / iOS | `RTCVideoSource` + `RTCVideoCapturer` | カスタム `RTCAudioDevice` の `deliverRecordedData` |
| Android | `VideoSource` の capturer observer | `setAudioRecordEnabled(false)` + `AudioBufferCallback` |
| Windows | `CreateCustomVideoSource` / `OnCapturedFrame` | `CreateAudioSource(kCustom)` / `CaptureFrame` |
| Web | Canvas の `captureStream(0)` / `requestFrame` | AudioWorklet → `MediaStreamAudioDestinationNode` |

## 再現

Python 3.12 以降、mise、Flutter の各 OS のビルド環境が必要です。Web の自動検証には Node.js 22 以降と Chrome を使います。

```sh
mise trust
mise run                    # local WebRTC の用意、pub get、analyze、Web build
mise run macos-autorun       # 合成入力と実カメラ・マイク。初回は OS の許可が必要

python3 tools/verify_results.py results/macos-real.json results/android-real.json \
  results/ios-real.json results/web-flutter-capture.json results/windows-browser-synthetic.json \
  results/windows-browser-record-profile-cleanup.json
```

Web の起動と headless 試験は [Web notes](web-notes.md)、Android の仕組みと注意点は
[Android notes](android-notes.md)、Windows は [Windows notes](windows-notes.md)、
macOS / iOS は [Darwin notes](darwin-notes.md) を参照してください。

ネイティブは `EXTERNAL_SYNTHETIC=true` で合成入力、`EXTERNAL_EXIT=true` で自動終了。
iOS は `tmp/external_config.json` に `{"synthetic":"false","exit":"true"}` を置きます。
Web は `?synthetic=true`。結果は `EXTERNAL_RESULT` のログと、ネイティブの一時ディレクトリにある
`external_result.json`、Web の `window.resultJson` に出ます。

## 制約と次に確認すること

- **音声送信の成立と、会話のエコー対策は別です。** `record` の AEC / NS / AGC は無効です。
  macOS / iOS のテスト ADM は受信音を pull して捨て、実スピーカー再生は実装しません。
  Windows の custom audio source は通常の音声処理を通らないので、WebRTC の AEC が適用されると扱いません。
  Android もハードウェア AEC / NS を無効にしています。スピーカーでの双方向会話は未検証です。
- Windows の `kCustom` source でも既定 ADM のマイク起動が試みられます。
  `record` のみがマイクを所有する保証には、wrapper / factory を拡張して既定録音を抑止する必要があります。
  検証機では 4ch 音声出力の初期化に失敗するため、ネイティブ同士の音声受信試験は失敗し、
  独立した Chrome を受信側にして注入・送信を検証しました。物理カメラは未接続です。
- macOS / iOS のカスタム音声デバイスは最初の WebRTC 操作より前に factory へ設定します。
  Android の外部入力設定も factory 全体に効き、WebRTC の通常のマイク取得を無効にします。
  既存の WebRTC 通話アプリへそのまま後付けする API ではありません。
- カメラ・マイクの独立した時計の補正、厳密な A/V 同期、長時間運転、バックグラウンド化、
  Bluetooth・デバイスの変更、複数の独立した外部音声トラックは未検証です。
- Web の camera plugin には画像ストリームがないため、ブラウザの `getUserMedia` + Canvas の
  アダプターを使います。物理デバイス、Safari、Firefox は未検証です。
- BGRA の Dart ↔ native コピーと色変換を使う成立性の試作です。解像度や fps を上げた負荷は未計測です。
  解析器そのものは載せず、同じ入力を分岐できるところまでを確認しています。
- 実機は各 OS 1 台だけです。全 Windows / Android / iPhone での動作保証にはなりません。

## 関連する実験

- [Always-on camera and microphone](../../../09/26/flutter-record-camera-senses/README.md)
- [WebRTC media taps](../../../09/25/flutter-webrtc-media-taps/README.md)

この lab は上記の実装を写して適応していますが、別 lab のコードを import しません。
