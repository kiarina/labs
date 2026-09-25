# GPT-Live over WebRTC from native Flutter, with idle and conversation capture switching

音声対話 AI の「目と耳」を、状態によって取り込み方を切り替える構成で作れるかを確かめます。

| 状態 | 取り込み |
| --- | --- |
| 待機中（A） | `record`（マイク）+ `camera` / `camera_desktop`（カメラ） |
| 会話中（B） | flutter_webrtc（マイクもカメラも）。マイクは OpenAI の GPT-Live（`gpt-live-1`）へ WebRTC で送り、解析用の音と映像は `media_taps`（flutter_webrtc のトラックにつなぐ受け口）で取る |

GPT-Live への接続は、公式の WebRTC の手順（アプリのサーバーが API キーを持って SDP を交換し、音声とイベントは端末と OpenAI の間を
直接流れる）を、ブラウザではなくネイティブの Flutter アプリから使います。

前提となる lab:
- [record + camera senses](../flutter-record-camera-senses/README.md)（待機中の取り込み。`record` の `echoCancel` があてにならないこと）
- [flutter_webrtc media taps](../../25/flutter-webrtc-media-taps/README.md)（`media_taps` の元。この lab にはコピーを置いている）

## Purpose

1. ネイティブの flutter_webrtc（macOS・Android・iOS）から、SDP だけを中継サーバーで交換して GPT-Live につながるか
2. 会話中、解析用の音と映像を `media_taps` で取れるか。映像の解像度は足りるか
3. 解析結果を `session.thinking.append` で渡すと、会話に使われるか。AI に話し出させるには何を送ればよいか
4. スピーカーのままで、AI が自分の声を拾って反応しないか（WebRTC の経路なので深くは測らず、各プラットフォームで一度見る）
5. 待機中 ↔ 会話中の切り替えに何秒かかるか、失敗しないか

## Answer

- **ネイティブの 3 プラットフォームすべてでつながり、会話できました**（macOS・Pixel Fold・iPad）。接続の開始から `session.started` まで
  1.4〜2.5 秒、そのうち中継サーバー経由の SDP の交換が 0.25〜1.1 秒でした
- **AI に話し出させるには `session.commentary.append` を送ります。** `session.instructions.append`（「いますぐ挨拶して」）だけでは、
  30 秒待っても話しませんでした
- **`session.thinking.append` で渡した解析結果（「赤いマグカップと青いノート」）を、AI は 3 つとも会話で使いました**
- **スピーカーのままでも、AI の声は利用者側の文字起こしに一度も入りませんでした**（人が実際に話した 3 回で確認）。割り込みにも応じました。
  macOS の WebRTC の音声処理は、同じ Mac が再生した音（`say` の声も）を丸ごと消します
- **会話中の映像は、制約を数値（`{'width': 1280, 'height': 720}`）で渡すと 1280×720 で取れました。** 前の lab で macOS と iPad が 640×480 だったのは、
  入れ子の `{'ideal': ...}` を渡していたためと考えられます
- **会話中 → 待機中の切り替えは、Android と iPad では 0.2〜0.4 秒で戻りましたが、macOS では 7 回中 3 回失敗しました**（マイクの最初の音が 16 秒遅れ、
  カメラが起動しない）。戻る前に 1.5 秒待つとカメラは戻るもののマイクは遅れたまま、会話の終了時に `stopLocalRecording` を呼んでも 4 回中 1 回失敗し、
  解決していません

## Architecture

```text
relay/  （Dart、dart:io のみ）
  POST /session  ← 端末の SDP offer（text/plain）
    → POST https://api.openai.com/v1/live/sessions
       {"session": {"model": "gpt-live-1", "instructions": ...}, "transport": {"type": "webrtc", "sdp": offer}}
    ← 201 {"session": {...}, "transport": {"sdp": answer}}
  → 端末へ answer（text/plain）。API キーはこのプロセスの外へ出ない

app/  （Flutter）
  A: AudioProbe（record, 16 kHz mono）+ CameraProbe（camera / camera_desktop）
  B: getUserMedia(audio, video 1280x720)
     RTCPeerConnection: マイクのトラックだけ addTrack、DataChannel "oai-events"
     media_taps: ローカルのマイク（エコー除去後）・カメラ、受信した AI の音声
media_taps/  （前の lab の plugin のコピー）
```

実行の流れ（1 回）: A を 5 秒 → B（接続 → `thinking.append` → `instructions.append` → 1.5 秒後に `commentary.append` → 指定秒数）→ A を 4 秒。
B の間は tap を 100 ms ごとに poll し、マイク（エコー除去後）と受信した AI の声の音量を 500 ms ごとに記録します。

## Results

機材: macOS は MacBook Pro M1 Max（内蔵のカメラ・マイク・スピーカー）、Android は Pixel Fold（Android 17、Wi-Fi）、iOS は iPad Air 第 4 世代
（iPadOS 26.6.2、Wi-Fi）。中継サーバーは同じ Mac で動かし、端末は LAN で接続。Flutter 3.47.2、flutter_webrtc 1.6.2+hotfix.3、release ビルド。
数値は `results/*.json`（人が話した回は、文字起こしの本文を伏せて文字数だけ残した）。

### 接続と会話（B）

| | SDP 交換 (ms) | 接続開始 → `session.started` (ms) | `session.started` → AI の最初の発話 (ms) | 映像（tap） | AI が解析結果を使った | AI の声が利用者側に入った |
| --- | --- | --- | --- | --- | --- | --- |
| macOS（`say` での確認） | 252 | 1,386 | 2,301 | 1280×720 CVPixelBuffer 420v | はい | いいえ |
| macOS（人が話した 90 秒） | 412 | 1,551 | 1,765 | 1280×720 CVPixelBuffer 420v | はい | いいえ |
| Pixel Fold（人が話した） | 1,102 | 2,465 | 1,761 | 1280×720 OES テクスチャ | はい | いいえ |
| iPad（人が話した） | 701 | 1,643 | 2,205 | 1280×720 CVPixelBuffer 420v | はい | いいえ |

- 「AI の最初の発話」は、`commentary.append` を送る 1.5 秒の待ちを含みます
- tap の音声は 3 つとも 48 kHz・モノラル・10 ms ごとに届きました（エコー除去の後の音）
- 会話の終了（`session.close` → `session.closed` → トラックの停止）は 0.8〜1.2 秒でした
- 請求の単位になる `usage.seconds` は、接続していた秒数とほぼ同じでした（30 秒の会話で 31 秒）

### AI の話し出し

- `instructions.append` だけを送った回（`results/macos-instructions-only.json`）は、受領の `session.instructions.appended` は返ったものの、
  30 秒間 AI は話さず、文字起こしも 0 件でした
- `commentary.append` を足すと、送ってから 0.3〜0.8 秒で AI が話し始めました。内容は `commentary.append` の文面にほぼそのままで、
  `thinking.append` で渡した「赤いマグカップと青いノート」も含まれていました

### エコー

- 人が話した 3 回とも、利用者側の文字起こし（`session.input_transcript.delta`）には利用者の言葉だけが入り、AI の言葉は入りませんでした。
  割り込むと AI は話をやめ、新しい話題に応じました
- macOS で AI が話している間、tap したマイク（エコー除去の後）の音量は 0.01 前後で、1 回だけ 0.04 まで上がりました
- **同じ Mac の `say` で流した声は、tap したマイクに一切入りませんでした。** macOS の voice processing は、同じ Mac が再生した音を
  AI の声に限らず消すので、利用者の声の代わりには別の端末か人の声が要ります

### 待機中 ↔ 会話中の切り替え

待機中 → 会話中は、`record` と `camera` を止めてから接続を始めるまで 0.1 秒でした。解析用の tap に最初の音と映像が届くまでは、
接続の開始から 3.0〜4.1 秒でした（`session.started` を待ってから poll を始めているので、実際より長めに出ます）。

会話中 → 待機中（`record` と `camera` を開き直してから、最初の音と映像が届くまで）:

| | 結果 |
| --- | --- |
| Pixel Fold | 音 242 ms、映像 200 ms |
| iPad | 音 410 ms、映像 432 ms |
| macOS（対策なし、7 回） | 4 回は 350〜375 ms / 374〜396 ms。**3 回は音が 15.6〜16.1 秒遅れ、カメラが `initialization_timeout` で起動しない** |
| macOS（戻る前に 1.5 秒待つ、4 回） | カメラは 4 回とも 0.3〜1.4 秒で戻る。音は 2 回が 4 秒以内に届かず、2 回は 0.27〜1.4 秒 |
| macOS（会話の終了時に `NativeAudioManagement.stopLocalRecording()`、4 回） | 3 回は 0.3〜0.6 秒。1 回は音が 16 秒遅れ、カメラが起動しない |

`results/macos-switch-back.json` に全回を載せています。macOS では、失敗するときは「音の遅れ」と「カメラの起動の失敗」が必ず一緒に起きました。
WebRTC の音声処理（CoreAudio の voice processing）がデバイスを放すまでの間に `record` と `camera_desktop` が開きに行って待たされる、と推定していますが、
確かめていません。

## Requirements and run

- Flutter 3.47.2（`.mise.toml`）、OpenAI の API キー（GPT-Live を使える project）
- 会話は 1 分あたり $0.05（秒単位）。この lab の計測（約 15 回、合計約 8 分）で 0.4 ドル程度

```sh
mise run                           # relay・plugin・app の analyze
OPENAI_API_KEY=... mise run relay  # 中継サーバー（0.0.0.0:8788）。OPENAI_ENV_FILE で env ファイルから読むこともできる
mise run macos-run                 # 別の端末で。macOS で A → B → A を 1 回（スピーカーから AI が話す）
```

モバイルは、中継サーバーの URL（`http://<Mac の LAN の IP>:8788/session`）を `relay` として渡します。Android は
`adb shell am start ... --es relay <url> --es seconds 30 --es exit true`、iOS はアプリの `tmp/live_config.json` に置きます
（前の lab と同じ方法）。iOS は初回にローカルネットワークの許可が出て、その回の接続は失敗します。Android の結果は logcat の
`LIVE_PART i/n` で、日本語はバイト数で行が切れるので `\uXXXX` にしてから分けています。

lab 用の設定として、iOS の ATS で `NSAllowsArbitraryLoads`、Android で `usesCleartextTraffic` を有効にしています（中継サーバーが LAN の HTTP のため）。
本番では HTTPS の中継サーバーにします。

## 未確認の事項と制約

- 各プラットフォームの会話は 1〜数回ずつで、会話の質（自然さ・遅延の体感）は人が 1 回話した印象の範囲です
- Web と Windows は試していません（Web は公式の想定どおりの経路。Windows は flutter_webrtc の tap は前の lab で動いている）
- macOS の切り替えの失敗の原因は未特定です。Android と iOS は 1 回ずつしか試しておらず、同じ問題が起きないとまでは言えません
- `session.instructions.append` で話し出さない理由は分かりません（文面や送るタイミングで変わる可能性がある）
- 映像は GPT-Live に送っていません（モデルが映像を受け取らないため）。解析結果を文章で渡すだけです
- delegation（裏で推論するモデル）は使っていません
