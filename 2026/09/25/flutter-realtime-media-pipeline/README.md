# Flutter realtime media pipeline: one Pure Dart pipeline over WebRTC and local capture

Flutter で、**WebRTC で受け取るリモートの映像と音声**と**端末のカメラとマイク**を、同じリアルタイム処理ロジックで
扱えるかを確かめます。処理ロジック（Domain と Application）は Flutter に依存しない Pure Dart のパッケージに置き、
入力（`MediaSource`）と出力（`ActionTransport`）の Adapter を差し替えても Pipeline のコードが変わらないことを、
Web / macOS / iOS / Android / Windows の 5 つで実機（Android はエミュレーター）を使って確認しました。

```text
MediaSource (WebRTC | Local camera+mic | Mock)
      ↓ MediaEvent
RealtimePipeline → MediaProcessor → ProcessingResult → Action      ← Pure Dart (core/)
      ↓
ActionTransport (RTCDataChannel | Local operation API | Mock)
```

## Purpose

本検証で明らかにしたい問いは次のとおりです。

1. Domain と Application を Pure Dart（Flutter・flutter_webrtc・`dart:html` などに依存しない）に保ったまま、
   5 つのプラットフォームでアプリとして動かせるか
2. `RealtimePipeline.run(session)` のコードを変えずに、`MediaSource` を Local / WebRTC / Mock に、
   `ActionTransport` を DataChannel / Local API / Mock に差し替えられるか（指示書の Definition of Done）
3. flutter_webrtc 1.6 で、Phase 1 に必要な「映像が届いている・FPS・解像度・音量」を Pure Dart のイベントとして
   どこまで取り出せるか。プラットフォームごとに何が違うか
4. 映像は latest-frame-wins、音声は上限付き queue という backpressure の方針が意図どおりに動くか
5. WebRTC の loopback（同じアプリの中の Peer A ↔ Peer B）と、端末をまたぐ WebRTC（signaling サーバー経由）で、
   Action が DataChannel を往復するか

評価は、各プラットフォームでモードごとに 12 秒（Mock は 6 秒）動かし、1 秒ごとに Ping、途中で 1 回 Move を送り、
最後の metrics を JSON で書き出して比べました。数値は `results/*.json` に残しています。

## Answer

- **境界は保てました。** `core/`（Domain + Application + Mock + stats の変換）は `pubspec.yaml` に実行時依存が 1 つも
  なく、`dart test` だけで 16 件のテストが通ります（約 5 秒）。同じ `RealtimePipeline` が
  5 つのプラットフォームすべてで、Mock・Local→Mock・Local→Local API・WebRTC loopback の 4 通り、
  さらに端末をまたぐ WebRTC（macOS → Chrome、macOS → iPad）で動きました。Pipeline 側の分岐は 0 です
- **Phase 1 の映像と音量は getStats のポーリングでしか取れません。** flutter_webrtc にはフレームごとの
  コールバックも音量のコールバックもないため、100 ms ごとの `getStats()` をイベントに変換しました。
  したがって `VideoFrameObserved` は「フレームごと」ではなく「ポーリングごとの最新フレーム」で、
  処理側に届くのは 1 秒あたり約 10 件です（フレーム番号は飛ぶ）
- **ローカルのカメラとマイクを観測するには、内部に loopback の PeerConnection が要ります。** stats は
  sender に載ったトラックにしか出ず、**接続していない sender だけではネイティブ 4 つ（macOS / iOS / Android /
  Windows）で映像のフレーム数も音量も 0 のまま**でした（Chrome では音量だけ取れた）。さらに、
  **ネイティブ（Windows・Android エミュレーター）では loopback の probe を付けるとカメラの取り込み解像度自体が
  下がりました**（Windows で 1280×720 → 480×270）。Phase 1 の手段としては使えますが、無料ではありません
- **backpressure は意図どおりです。** 処理が遅いときの映像は最新の 1 枚だけが残り、遅延は処理 1 回分から
  伸びませんでした（単体テスト）。実機では処理が軽いため、どのプラットフォームでも落としたフレームは 0 でした
- **DataChannel の往復は通ります。** Ping → Pong の RTT は、同じプロセスの loopback で 1.5〜15 ms、
  Wi-Fi 越しの macOS ↔ iPad で 41.7 ms でした
- 指示書のコード例には、そのままでは成り立たない箇所が 4 つありました（[指示書から変えた点](#指示書から変えた点)）

## Architecture

### パッケージの分け方

指示書は 1 つの Flutter アプリの中に `lib/domain/` と `lib/application/` を置く構成でしたが、この lab では
**Pure Dart であることをパッケージの境界で強制する**ために 2 つに分けました。

```text
core/   realtime_core — Pure Dart。dependencies 無し（dev_dependencies に test と lints だけ）
  lib/src/domain/        MediaSource, MediaEvent, ActionTransport, Action, SignalingClient, MonotonicClock, AppLogger
  lib/src/application/   RealtimePipeline, MediaEventIntake (backpressure), SessionController, DebugMediaProcessor,
                         JsonActionCodec, ActionResponder
  lib/src/adapters/      WebRtcStatsParser, StatsEventConverter（W3C stats の Map → MediaEvent。flutter_webrtc の型は使わない）
  lib/src/local/         LocalOperationTransport, SimulatedOperationApi
  lib/src/mock/          MockMediaSource, SyntheticMediaSource, MockActionTransport, InMemorySignalingClient
  bin/signaling_server.dart   2 台構成用の WebSocket relay（dart:io。lib の外なので Pure Dart の制約は受けない）
  test/                  pipeline / session / stats / architecture のテスト

app/    realtime_pipeline_app — Flutter
  lib/infrastructure/webrtc/   PublisherPeer, ViewerPeer, WebRtcMediaSource, RtcDataChannelTransport, WebSocketSignalingClient
  lib/infrastructure/local/    LocalMediaSource（getUserMedia + stats probe）
  lib/app/dependency_container.dart   手動 DI。具体的な Adapter を選ぶのはここだけ
  lib/presentation/            Home / Session / Publisher 画面
```

`core/test/architecture_test.dart` は、`core/lib` が `package:flutter/`・`package:flutter_webrtc/`・`dart:html`・
`dart:js_interop`・`dart:ffi`・`dart:io`・`dart:ui` を import していないことと、`pubspec.yaml` に
`dependencies:` が無いことを確かめます。

### 処理経路と描画経路

プレビューは Pipeline を通しません。`LocalMediaSource` と `WebRtcMediaSource` は `VideoPreviewSource`
（`ValueListenable<MediaStream?>`）も実装し、画面はそれを `RTCVideoView` に渡します。この interface は
Flutter の型を含むので `app/` 側に置いています。

### Phase 1 の観測方法

| 入力 | 観測する PeerConnection | 使う stats |
| --- | --- | --- |
| WebRTC（リモート） | 受信側の PeerConnection | `inbound-rtp` の `framesDecoded`・`frameWidth`/`Height`・`framesPerSecond`、`audioLevel`、`candidate-pair` の RTT |
| Local（`probe=loopback`） | 取り込んだトラックを載せた sender と、同じプロセスの receiver をつないだ組 | sender 側の `media-source` の `frames`・`width`/`height`、`audioLevel` |
| Local（`probe=sender`） | sender だけ（offer を作って setLocalDescription するが、接続しない） | 同上 |
| Local（`probe=none`） | 無し | 開始と停止のイベントだけ |

stats の Map から `MediaEvent` への変換（`StatsEventConverter`）は Pure Dart なので、`core/` でテストしています。
Android では一部の数値が文字列で返るため、数値の読み取りはすべて文字列も受け付けます。

### モード

| key | MediaSource | ActionTransport | 備考 |
| --- | --- | --- | --- |
| `mock` | `SyntheticMediaSource`（30 fps、音量は 2 秒周期の正弦波） | `MockActionTransport`（Ping に Pong を返す） | 指示書の 5 |
| `local-mock` | `LocalMediaSource` | `MockActionTransport` | 指示書の 1 |
| `local-api` | `LocalMediaSource` | `LocalOperationTransport` → `SimulatedOperationApi`（Move でカーソルが動く） | 指示書の 2。HTTP ではなく同じプロセスの API |
| `loopback` | `WebRtcMediaSource`（Peer B） | `RtcDataChannelTransport`（Peer B → Peer A） | 指示書の 4。Peer A はカメラとマイクを送り、Action に Pong を返す |
| `webrtc` | `WebRtcMediaSource`（viewer） | `RtcDataChannelTransport` | 指示書の 3。相手の端末は `publisher` モードで動かす |

`DebugMediaProcessor` は、音量が 0.7 を上に跨いだときに `audio_peak`、フレーム番号が 30 の倍数を跨いだときに
`video_tick` を出します。フレーム番号が飛ぶので、`sequence % 30 == 0` ではなく「30 ごとの区間が変わったか」で判定します。

## 指示書から変えた点

| 指示書 | 問題 | この lab |
| --- | --- | --- |
| `audio_event.dart` と `video_event.dart` に `MediaEvent` の子クラスを分ける | `sealed class` の子クラスは同じ library にしか置けない | `media.dart` 1 つにまとめた |
| `Future<List<MediaDevice>> get availableDevices();` | getter に引数リストは付けられない（構文エラー） | メソッド `availableDevices()` にした |
| `RealtimePipeline.run` が `await for` で 1 件ずつ処理する | 処理が遅いと、届いたイベントがすべて Stream の中に上限なく溜まり、latest-frame-wins にならない。また、broadcast の Stream を使う Adapter では、購読前に出たイベントが消える | `run` の最初（await より前）に購読し、`MediaEventIntake`（映像は 1 枠、音声は上限付き FIFO、制御イベントは落とさない）を挟んだ |
| Domain で禁止する import に `dart:io` が無い | Web では `dart:io` が使えない | `dart:io` と `dart:ui` も禁止した |
| `Action` という名前 | Flutter の widgets library にも `Action` がある | 名前は変えていない。両方を import したファイルで `Action` を**使ったとき**だけ曖昧さのエラーになる（今回の UI では使わなかった） |
| RTT を測る手段が無い | Ping に対する返事が定義されていない | `PongAction` を足した |
| `MediaErrorOccurred(code, message)` | — | `MediaFailure`（sealed）を持たせ、`MediaException` で Application へ投げる形にした |

## 結果

### 実行環境

| プラットフォーム | 機材 | OS | カメラとマイク |
| --- | --- | --- | --- |
| Web | MacBook Pro M1 Max | Chrome 153 headless | Chrome の fake device（`--use-fake-device-for-media-stream`） |
| macOS | MacBook Pro M1 Max | macOS 26.6.2、Xcode 27.0 | 内蔵 |
| iOS | iPad Air（第 4 世代） | iPadOS 26.6.2 | 内蔵 |
| Android | Android 13 (API 33) arm64 エミュレーター（MacBook Pro M1 Max 上） | — | エミュレーターの virtual scene、マイクはホスト |
| Windows | デスクトップ PC | Windows 11 25H2（10.0.26220）、Visual Studio 2022 17.14 | 接続済みの USB カメラ |

すべて Flutter 3.47.2（Dart 3.13.2）、flutter_webrtc 1.6.2+hotfix.3、release ビルドです。

### モード × プラットフォーム（12 秒。iOS と Windows の mock だけ 6 秒）

表の値は `results/<platform>-<mode>-<probe>.json` の `metrics` と `diagnostics` から取りました。
「解像度」は Pipeline が受け取った値（stats 由来）、「fps」は Pipeline がフレーム番号の増え方から計算した値です。

| プラットフォーム | モード | 解像度 | fps | video_tick / audio_peak | 送った / 受けた Action | RTT (ms) | 遅延 平均 / 最大 (ms) | getStats 平均 / 最大 (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Web | mock | 1280×720 | 30.4 | 12 / 6 | 30 / 11 | 9.3 | 0.08 / 5.2 | — |
| Web | local-mock | 1280×720 | 20.1 | 7 / 23 | 42 / 11 | 6.3 | 0.03 / 0.3 | 2.1 / 10.3 |
| Web | local-api | 1280×720 | 20.0 | 7 / 23 | 42 / 11 | 0.2 | 0.06 / 0.6 | 2.2 / 10.6 |
| Web | loopback | 480×270 | 20.0 | 7 / 16 | 35 / 11 | 3.7 | 0.23 / 70.1 | 1.1 / 3.8 |
| macOS | mock | 1280×720 | 30.3 | 11 / 6 | 29 / 11 | 0.29 | 0.02 / 0.18 | — |
| macOS | local-mock | 640×480 | 25.6 | 10 / 0 | 22 / 11 | 0.21 | 0.01 / 0.03 | 12.7 / 945 |
| macOS | local-api | 640×480 | 26.1 | 10 / 0 | 22 / 11 | 0.11 | 0.01 / 0.08 | 13.7 / 1041 |
| macOS | loopback | 640×480 | 26.1 | 8 / 0 | 20 / 11 | 10.1 | 0.83 / 233 | 15.5 / 1034 |
| iOS | mock | 1280×720 | 30.5 | 5 / 3 | 14 / 5 | 0.25 | 0.02 / 0.08 | — |
| iOS | local-mock | 640×480 | 60.2 | 23 / 1 | 36 / 11 | 0.39 | 0.01 / 0.10 | 4.6 / 143 |
| iOS | local-api | 640×480 | 60.0 | 23 / 0 | 35 / 11 | 0.30 | 0.02 / 0.10 | 4.6 / 153 |
| iOS | loopback | 640×480 | 60.7 | 22 / 0 | 34 / 11 | 3.1 | 0.66 / 190 | 4.6 / 233 |
| Android | mock | 1280×720 | 30.3 | 11 / 6 | 29 / 11 | 1.1 | 0.02 / 2.4 | — |
| Android | local-mock | 720×1280 | 11.3 | 4 / 0 | 16 / 11 | 3.2 | 0.01 / 0.63 | 3.7 / 16.2 |
| Android | local-api | 720×1280 | 11.3 | 4 / 0 | 16 / 11 | 0.35 | 0.01 / 0.23 | 3.4 / 30.6 |
| Android | loopback | 480×270 | 11.3 | 3 / 0 | 15 / 11 | 5.4 | 3.2 / 697 | 5.1 / 89.0 |
| Windows | mock | 1280×720 | 30.3 | 5 / 3 | 14 / 5 | 0.15 | 0.01 / 0.05 | — |
| Windows | local-mock | 480×270 | 30.0 | 11 / 0 | 23 / 11 | 1.4 | 0.00 / 0.28 | 1.3 / 2.4 |
| Windows | local-api | 480×270 | 30.1 | 11 / 0 | 23 / 11 | 0.08 | 0.01 / 0.07 | 1.8 / 8.8 |
| Windows | loopback | 640×360 | 29.8 | 11 / 0 | 23 / 11 | 1.7 | 0.76 / 189 | 1.7 / 19.5 |

- local と loopback の probe は `loopback`。落としたフレームと音声イベントは、すべての行で 0 でした
- 「遅延」は、イベントが Pipeline に入ってから Action を Transport に渡し終えるまでの時間です（intake で待った時間を含む）
- iOS と Windows の Mock は 6 秒のため、ほかの Mock と件数が違います
- audio_peak が 0 の行は、部屋が静かで音量が 0.7 を超えなかったものです（Chrome の fake device は周期的にビープを鳴らす）

### 端末をまたぐ WebRTC（`publisher` ↔ `webrtc`）

`core/bin/signaling_server.dart` を Mac で動かし、Mac の macOS アプリを `publisher`（カメラとマイクを送り、Action に
Pong を返す）にして、別のアプリを `webrtc`（viewer。受け取った映像と音声を Pipeline に流し、Action を DataChannel で返す）
にしました。

| viewer | 経路 | 解像度 / fps | viewer が送った Action | publisher が受けた Action | RTT (ms) |
| --- | --- | --- | --- | --- | --- |
| Chrome headless（同じ Mac） | localhost | 640×480 / 25.3 | 25 | 26 | 0.9 |
| iPad Air（第 4 世代） | Wi-Fi LAN | 640×480 / 26.0 | 34 | 34 | 41.7 |

送った数と受けた数の 1 件の差は、viewer の metrics を最後に更新した時点（250 ms ごと）と、publisher が数えた時点の
ずれです。libwebrtc（ネイティブ）と Chrome の間でも、映像・音声・DataChannel がつながりました。

### Local の stats probe の比較

| プラットフォーム | `probe=sender` の映像フレーム数 | `probe=sender` の音量 | プレビューの解像度（sender） | プレビューの解像度（loopback） |
| --- | --- | --- | --- | --- |
| Web | 0 | 取れた（0.015） | 1280×720 | 1280×720 |
| macOS | 0 | 0.0 | 640×480 | 640×480 |
| iOS | 0 | 0.0 | 640×480 | 640×480 |
| Android | 0 | 0.0 | 1280×720 | 480×270 |
| Windows | 0 | 0.0 | 1280×720 | 480×270 |

プレビューの解像度は、画面の `RTCVideoRenderer` の `videoWidth`/`videoHeight` です（`results/*.json` の `renderer`）。

観測した事実:

- 接続していない sender では、どのプラットフォームでも `media-source` の `frames` が増えませんでした。音量は Chrome だけで取れました
- Android と Windows では、loopback の probe を付けたときだけプレビューの解像度が下がりました。macOS と iOS は
  どちらでも 640×480、Chrome はどちらでも 1280×720 で変わりませんでした

解釈（未検証）: libwebrtc のエンコーダーは、接続直後の推定帯域が小さいと解像度を下げます。ネイティブではこの調整が
取り込み元（カメラ）の出力に掛かり、同じトラックを表示しているプレビューにも出ると考えています。Chrome は
エンコーダーの入力だけを縮めるので、トラック自体は変わりません。

### その他の観測

- **macOS と iPad のカメラは 640×480 でした。** `width: {ideal: 1280}` などの制約を渡しましたが、macOS のログには
  `target format 0x0, targetFps: 0, selected format: 640x480` と出ており、ネイティブの flutter_webrtc は入れ子の
  `ideal` を読んでいないように見えます（未検証）。iPad は 60 fps で出しました
- **loopback の最初の数秒は解像度が下がります**（Chrome と Android で 480×270）。ネイティブの macOS / iOS は下がりませんでした
- **遅延の最大値（70〜700 ms）は、DataChannel が開くまでの待ち時間です。** Pipeline は `ActionTransport.connect()` を
  終えてから処理を始めるので、その間に届いたイベントは intake で待ちます。開いた後の遅延は 1 ms 未満でした
- **macOS の getStats は遅く、ばらつきます。** 平均 13〜16 ms、最大で約 1 秒でした。ほかのプラットフォームは平均 1〜5 ms です
- Android エミュレーターの virtual scene カメラは縦長（720×1280）の約 11 fps でした

## Pure Dart の比率

空行とコメント行を除いた Dart の行数です（テストを除く）。

| 場所 | 行数 | Pure Dart |
| --- | --- | --- |
| `core/lib/src/domain` | 302 | ✓ |
| `core/lib/src/application` | 791 | ✓ |
| `core/lib/src/adapters`（stats → MediaEvent） | 229 | ✓ |
| `core/lib/src/local`（operation API） | 96 | ✓ |
| `core/lib/src/mock` | 219 | ✓ |
| `core/lib`（barrel） | 15 | ✓ |
| `app/lib/infrastructure` | 688 | |
| `app/lib/app`（DI、環境変数） | 303 | |
| `app/lib/presentation` | 696 | |
| `app/lib/main.dart` | 58 | |

- UI を含むアプリ全体: 1,652 / 3,397 = **48.6 %**
- UI を除いたロジック（core + infrastructure + DI）: 1,652 / 2,643 = **62.5 %**
- DI の配線も除く（core + infrastructure）: 1,652 / 2,340 = **70.6 %**

指示書の目標「アプリ固有ロジックの 70〜80 % 以上」は、DI の配線をロジックに数えない場合に届きます。`app/lib/app` には
計測のための autorun と環境変数の読み取りが含まれており、本番のアプリでは減る部分です。このほかに、Android の
`MainActivity.kt`（18 行）と Windows の `CMakeLists.txt` の変更があります。

## Requirements and run

- Flutter 3.47.2（`.mise.toml`）。macOS と iOS は Xcode 27、Windows は Visual Studio 2022 の
  「C++ によるデスクトップ開発」（MSVC v143・C++ CMake tools・Windows SDK）
- Web の自動実行は Google Chrome

```sh
mise run                 # core のテスト、app の analyze、Web の build
mise run core-test       # core だけ（dart test。Flutter 不要）
mise run web-autorun     # headless Chrome で 6 通りを実行し results/web-*.json を書く
mise run macos-autorun   # macOS の実機カメラで 6 通りを実行し results/macos-*.json を書く（初回は権限の確認が出る）
mise run signaling       # 2 台構成用の signaling relay（ポート 8787）
```

アプリを手で動かす場合は `cd app && flutter run -d <device>` で起動し、ホーム画面でモードを選びます。
2 台構成は、片方で `mise run signaling` を動かし、両方の Signaling URL をそのマシンに向け、
片方で「Publisher」、もう片方で「WebRTC → DataChannel (viewer)」を選びます。

### 自動実行（autorun）の指定方法

同じビルドで全モードを回せるよう、プラットフォームごとに次の方法で `autorun`・`probe`・`seconds`・`exit`・
`signaling`・`room` を渡します。結果は `REALTIME_RESULT {json}` の 1 行で出力し、ネイティブでは
一時ディレクトリの `realtime_result.json` にも書きます。

| プラットフォーム | 渡し方 | 結果の受け取り方 |
| --- | --- | --- |
| Web | URL の query（`?autorun=loopback&seconds=12`） | ブラウザの console |
| macOS / Windows | 環境変数 `REALTIME_AUTORUN` など | macOS は `open --stdout`、Windows は `%TEMP%\realtime_result.json` |
| iOS | `devicectl device copy to` でアプリの `tmp/realtime_config.json` に置く | `devicectl device copy from` で `tmp/realtime_result.json` を取る |
| Android | `adb shell am start ... --es autorun loopback`（`MainActivity` が `REALTIME_*` 環境変数に写す） | logcat の `REALTIME_PART i/n`（下記） |

`--dart-define=AUTORUN=...` でも指定できます。

### 手順の中で踏んだもの

- **Flutter 3.41.2 は Xcode 27 で macOS をビルドできません。** Xcode 27 の `lipo` が
  `lipo <file> -verify_arch arm64 x86_64` の形を受け付けなくなり（`-verify_arch requires exactly one input file`）、
  Flutter の `release_unpack_macos` が「架構が含まれていない」と誤判定します。3.47.2 では通りました
- **macOS の deployment target は 12.0 以上が必要です。** Xcode 27 は 10.15 を受け付けないため、Podfile の
  `platform` と `post_install` で Pod 側も 12.0 に揃えています
- **iOS の release ビルドでは、Dart の `print` が `devicectl ... --console` に出ません**（成功した実行でも 0 行）。
  また、`devicectl process launch --environment-variables` と `DEVICECTL_CHILD_` 接頭辞で環境変数を渡した起動では、
  autorun が始まりませんでした。環境変数が届かないのか、その時に端末の画面が消えていたのかは切り分けていません。
  設定と結果をアプリの `tmp/` のファイルでやり取りする形にしてからは、毎回動きました
- **Android の `print` は 1 行を約 1 KB で切ります**（続きは捨てられる）。Android だけ 800 文字ずつに分けて
  `REALTIME_PART i/n` として出しています
- **Flutter の Android release ビルドには `isDebuggable = true` が効かず**、`run-as` でファイルを置けません。
  intent の extra を `Os.setenv` で環境変数に写す形にしました
- **日本語ロケールの Windows では flutter_webrtc の C++ がビルドできません。** ソースの非 ASCII 文字が
  コードページ 932 で読めず C4819 になり、`/WX` でエラーになります。`windows/CMakeLists.txt` の
  `APPLY_STANDARD_SETTINGS` に `/utf-8` を足しました
- Windows の GUI アプリは、SSH のセッションから起動しても画面に出ません。対話セッションで動くスケジュールタスクから起動しました
- iOS でカメラ・マイク・ローカルネットワークを使うには、初回に端末で許可が必要です

## 未確認の事項と制約

- **Phase 2（生の映像フレームと音声 PCM）は扱っていません。** 今回の Local の観測は stats 経由なので、フレームの
  中身はまったく見ていません。上の probe の観測から、ローカルの映像を実際に処理するなら、stats ではなく
  プラットフォームごとのフレームの取り出し口が必要だと考えています
- Android は実機ではなくエミュレーターです。Android 実機と、iPhone は試していません
- Web は Chrome の fake device だけです。Safari と Firefox、実カメラのブラウザは試していません
- カメラとマイクの切り替え（デバイス選択）、`Mute Mic` / `Disable Camera`、アプリのバックグラウンド化と復帰は、
  実装はしていますが自動実行では確かめていません
- 複数の USB カメラの列挙、TURN を使う NAT 越え、長時間の連続実行は対象外です
- 各条件 1 回ずつの計測で、ばらつきは測っていません。RTT と遅延の最大値は、接続直後の一時的な値を含みます
- `Local → Local API` は同じプロセスの模擬 API です。HTTP などプロセスをまたぐ操作 API は試していません
