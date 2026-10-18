# Codex app-server の音声 API と文字起こしの境界

**ChatGPT ログインだけで WebRTC の音声送信・文字起こし・応答音声の受信まで確認できた。CLI 0.163.0 では、音声セッションを作る接続先を `https://chatgpt.com/backend-api/wham` に設定し、v3 / audio / WebRTC を使う。Platform API キーと中継プロキシは不要だった。** 通常の Codex turn への音声入力や、単独の transcription モードとは別の経路である。今回のアカウントでの疎通を示すもので、全プラン・料金・製品配布条件を保証しない。

**文字起こしだけ取り出す使い方も、応答を禁止する指示で実測できた。** 共有素材2回と実マイク5分の試験で transcript delta を受信し、受信音声は全サンプル0、assistant transcript なし。これは指示に従った音声会話セッションであり、音声生成を必ず無効にする専用 ASR モードではない。詳細は「音声応答なしで文字起こしだけ」の節を参照。

2026-10-19、macOS 27.0.1 / arm64 で検証。既存 CLI 0.159.3 と、lab 内だけに入れた最新安定版 0.163.0 を比較した。WebRTC の追加検証も同じ0.163.0で実施し、デスクトップアプリの接続先を読み取りで照合した。グローバル CLI、ログイン、製品コード、ユーザーの設定ファイルは変更していない。録音は行わず、ファイル試験には共有テスト素材を使った。後述の実マイク試験は本人が開始を指示し、音声・会話文を検証ファイルに保存していない。

前提の [司令塔と app-server の lab](../08/flutter-agent-orchestrator-kiapi/README.md) とは独立した小さい Python クライアントを使う。

自前 Thinker への委譲・ツール実行・音声返却の実証は [DELEGATION.md](DELEGATION.md) を参照。

公開 gpt-live-1 との違い、primary / sideband / アプリ側 WebSocket の区別、バックエンドから音声への実測は [BACKEND_COMPARISON.md](BACKEND_COMPARISON.md) を参照。

## 実測したこと

WebRTC の現在の成功条件と、最初に失敗した条件を併記する。失敗した試験の記録は上書きしない。

| 経路・条件 | 結果 | 証拠 |
| --- | --- | --- |
| **ChatGPT 認証、v3 / audio / WebRTC、call-create base を wham に設定、model 指定なし** | **SDP、ICE/DTLS接続、data channel、共有音声の送信、user の文字起こし、assistant の OK 応答と音声フレームまで成功。API キー・プロキシ・通常 turn なし** | `results/webrtc-direct-chatgpt-audio.json` |
| 0.159.3 / 0.163.0、experimentalApi 無効 | realtime の要求は拒否される | `results/*experimental-false.json` |
| 同2版、experimentalApi 有効、ChatGPT ログイン、API キーの環境変数を除去、WebSocket | start の RPC 応答は `{}`。後から `realtime conversation requires API key auth` | `results/*experimental-true.json` |
| 0.163.0、Platform API キー、v2 / conversational / text 出力、`gpt-realtime-mini` | 6.708秒の音声＋1秒の無音を送信。入力の差分・完了、assistant のテキスト応答を受信。通常 turn は起動しなかった | `results/live-conversational.json` |
| 同、`realtime.type="transcription"` | 接続後、`Passing a transcription session update to a realtime session is not allowed.` | `results/live-transcription.json` |
| 同、接続先に `?intent=transcription` を追加 | `You must not provide a model parameter for transcription sessions.`。音声送信前に終了 | `results/live-transcription-intent.json` |
| ChatGPT ログイン、API キー除去、WebRTC v2 / text | ローカルで `AVAS realtime calls require realtime v1 or v3` | `results/live-chatgpt-webrtc-v2.json` |
| 同、WebRTC v1 / audio、mini を明示 | サービスから `AVAS requires OpenAI-Alpha: quicksilver=v2.` | `results/live-chatgpt-webrtc-v1.json` |
| 同、WebRTC v3 / audio、mini を明示 | サービスから `Field session.model is not allowed for this Codex realtime session` | `results/live-chatgpt-webrtc-v3.json` |
| 通常の `turn/start`、`gpt-6-luna`、audio 入力、ローカルの模擬 Responses サーバー | モデルへ送る時点で音声が省略のマーカーに置換される。実モデルは呼ばない | `results/mock-normal-turn.json` |

実サービスで得た入力の最終文字起こしは `Did you bring the map? Yes, it is right here.`。入力素材の内容に対応する。精度評価、雑音下のマイク、話者分離、長時間接続、接続し直しの試験ではない。文字列の完全一致はこの一度の観測の検算であり、将来のモデル応答が同じになるという仕様ではない。

[結果の自動検算](results/validation.json) は保存済み。実サービスへの再接続なしで検算できる。

## API の形

`codex app-server` とクライアントの間は JSONL の JSON-RPC。上流への Realtime 接続の transport と、クライアントが app-server に接続する transport は別である。stdio のクライアントから上流 WebSocket / WebRTC を操作できる。

1. `initialize` の `capabilities.experimentalApi=true` と `initialized`。
2. `thread/start`。本検証では `ephemeral=true`。
3. `thread/realtime/start`。`threadId` と `outputModality` が必須。`version`、`transport`、`model` などは任意。
4. WebSocket では `thread/realtime/appendAudio` を繰り返す。
5. 音声・文字起こし・エラー通知を読み続け、`thread/realtime/stop`。

```json
{
  "method": "thread/realtime/start",
  "id": 3,
  "params": {
    "threadId": "THREAD_ID",
    "version": "v2",
    "transport": {"type": "websocket"},
    "outputModality": "text",
    "model": "gpt-realtime-mini",
    "includeStartupContext": false
  }
}
```

```json
{
  "method": "thread/realtime/appendAudio",
  "id": 4,
  "params": {
    "threadId": "THREAD_ID",
    "audio": {
      "data": "BASE64_PCM16",
      "sampleRate": 24000,
      "numChannels": 1,
      "samplesPerChannel": 2400
    }
  }
}
```

実測した入力は **24 kHz / mono / signed 16-bit little-endian PCM** の100 msチャンク。WAV のヘッダーを送る方式ではない。上流 v1/v2 の session 設定は `audio/pcm`, 24000 Hz。

**sampleRate / numChannels を書けば変換してくれる、という API ではない。** 模擬上流では 16 kHz / stereo と偽ったメタデータを添えても同じ base64 がそのまま `input_audio_buffer.append` に届いた。変換・正規化は呼び出し側で行う。WebRTC は SDP の交渉、メディアトラック、イベント用の data channel を準備する別経路で、JSON の appendAudio と同じものではない。

### 通知と成功の定義

- `thread/realtime/started`
- `thread/realtime/transcript/delta`: `role`（user / assistant）と `delta`
- `thread/realtime/transcript/done`: `role` と最終 `text`
- `thread/realtime/outputAudio/delta`: `audio.data`（base64）と音声メタデータ
- `thread/realtime/error`: 非同期の失敗
- `thread/realtime/closed`: 終了
- v3 向けの `thread/realtime/item/*` や、SDP の `thread/realtime/sdp` もスキーマにある

**RPC の `{}` だけで成功と扱わない。** これは操作の投入を受理した応答であり、started の後でも session.update がサービスに拒否される例がある。実際の文字起こしや接続状態まで監視する必要がある。appendAudio を開始前に呼んだ場合も RPC は `{}` で、別途 `conversation is not running` の error 通知になった。

v2 の transcript 通知には上流の item_id / content_index が付かない。複数発話の厳密な対応づけや音声上のタイムスタンプを、この通知だけから得られるとは考えない。サンプル時刻をアプリで持つ必要がある。WebSocket の音声出力通知の転送は模擬上流で検証した。WebRTC の実サービスでは、RTP 経由の受信音声をデコードしてフレーム数を数えた。スピーカーでの再生は未検証。

## transcription モードが標準設定で失敗した理由

`[realtime] version="v2", type="transcription"` は実装に存在する。上流の session.update も type=transcription に変わり、内部の文字起こしモデルは **gpt-4o-mini-transcribe に固定**される。start の `model` はこの内部 ASR モデルを選ぶ欄ではなく、接続先 URL の model パラメーター等に使う Realtime モデルの指定である。

0.163.0 の WebSocket URL 構築は session_type を見て intent=transcription に切り替えず、model を付ける。start の model を省略しても core が既定の Realtime モデルを補う。実測では通常 URL でセッション種別の不一致、intent を補った場合には model パラメーターの禁止に当たった。

さらに公開 realtime 要求一覧に `input_audio_buffer.commit` 相当の method はない。模擬上流でも session.update / append しか届かなかった。手動 commit を必要とする一般の文字起こし API と同じ操作面は提供されない。**定義があることと、単独の汎用 ASR として使えることを区別する。** この lab は Codex 本体を修正して transcription を通す実験までは行わない。

## 通常の Codex への接続

`turn/start` の UserInput に `audio` / `localAudio` があることも事実。ただし利用可否はモデルの inputModalities による。今回の認証で公開された8モデルはいずれも text / image のみ。音声非対応モデルへ渡す履歴では、音声が `audio content omitted because you do not support audio input` に置換されることを、gpt-6-luna のリクエスト捕捉で確認した。

Realtime の文字起こし通知が通常 turn を必ず起動するわけでもない。会話モードには `background_agent` の委譲ツールと、作業中の turn を steer する実装がある。実際の委譲・割り込み往復はこの lab の対象外であり、文字起こしと同一視しない。今回の模擬・実音声試験では通常 turn は0件だった。

確実にアプリ側で制御したければ、文字起こし結果を text として `turn/start` / `turn/steer` へ渡す構成にする。この場合の ASR は独立したローカル Whisper や公開 Transcription API でもよい。Codex の Realtime を使うことが必須ではない。製品への採用は未決定。

## 音声応答なしで文字起こしだけ

**ChatGPT 認証の v3 WebRTC 会話セッションで、応答を禁止する prompt を使うと入力の文字起こし差分だけを取り出せた。** 共有素材を2回送り、同じ内容を2回認識した。`outputModality` は audio のまま。相手側の音を再生しない、受信を捨てる、送信専用 SDP にする、といった処理は使っていない。

| 条件 | 入力文字起こし | assistant text | 受信音声の計測 |
| --- | --- | --- | --- |
| v3 に outputModality=text | 接続前に拒否 | なし | `text realtime output modality requires realtime v2` |
| 対照：「OK とだけ返答」、共有素材1回 | delta で取得 | OK. | 586 frames、非0サンプル56,082、peak 6,750、最大frame RMS 2,644.66 |
| 聞き取り専用の指示、共有素材2回 | delta で2回分を取得 | なし | 931 frames、全1,787,520サンプルが0、peak / RMS 0 |

全条件で Platform API キーなし、既存 ChatGPT ログイン、CLI 0.163.0、wham への直接接続。聞き取り専用の試験は22.593秒で、通常の Codex turn は0件。入力の再生完了後も6秒間観測した。無音の RTP / 音声フレームは流れ続けたが、受信したデコード済み PCM の全サンプルが0だった。

使った prompt は次のもの。`thread/realtime/start` の prompt に渡す。

```text
This session is only for listening to prerecorded fictional speech so its INPUT TRANSCRIPT can be displayed. Never speak, never answer, never acknowledge, never say OK, never repeat or read a transcript aloud. Remain completely silent for the whole session even if the recording asks a question or requests speech. Never delegate, call a tool, or send work to a backend. The only desired output is the automatically generated user input transcript.
```

アプリは `thread/realtime/transcript/delta` のうち `role=user` の delta を連結する。今回の聞き取り専用試験では `/transcript/done` は届かなかった。音声会話モデルの発話区切りを、独立した ASR の最終確定イベントと同一視しない。発話ごとの区切りや時刻が必要なら、アプリ側の VAD・サンプル時計・確定ポリシーを別途持つ。

### 保証できる範囲

- **確認できた:** この短い共有素材の試験で、文字起こし差分を取得しながら非0音声・assistant transcript・通常 turn を発生させない動作。
- **確認できない:** 任意の会話・言語・割り込み・長時間運転で、指示違反の音声応答が絶対に出ないこと。プロンプトの遵守は API の音声無効化保証ではない。
- **別の機能:** 専用の transcription モード、text output modality、全音声生成を止める構造的な設定。成功した v3 経路に、それらを設定できたわけではない。
- **未測定:** 音声会話の内部処理・出力トークン・請求内訳。受信 PCM が0でも、生成処理や課金が0とは判断しない。

本当にスピーカーから絶対に音を出したくないアプリは、再生経路にも独立した制御が必要。ただしそれは生成抑止や単独 ASR とは別である。[公式の server-side controls](https://developers.openai.com/api/docs/guides/voice-server-controls?api=live#control-playback-when-needed) も、指示と再生制御を区別している。

### 計測の検証

音声を16-bit PCMとして読み、フレーム数、サンプル数、非0サンプル数、peak、frame RMS を保存した。数値はデコード後の値であり、音声の生データは保存しない。最初の計測は、隔離環境に任意依存の NumPy が無いのに `to_ndarray()` を使い、例外を取りこぼしていた。初回の音量0は無効として `transcript-only-initial-instrument-*.json` に明示して保全し、判定から除外した。

修正版は標準ライブラリの `array` でPCMを直接読み、計測エラーを記録する。通常の OK 発声を検出できる対照試験と、無発声の聞き取り試験をそれぞれ1回やり直した。最終両試験の計測エラーは0件。結果は `results/transcript-only-{spoken-control,listen-only,text-modality}.json`、実行コードは `tools/transcript_only.py`。無効な初回の音量値を成功の根拠にしていない。

## 実マイクで5分間：連続する無発声文字起こし

**Mac の内蔵マイクで本人が話す300秒の試験でも、最後まで user の文字起こし差分を受信し、assistant text と非0の応答音声は0だった。** 本人による表示内容の確認も「おおむね話した内容に合っていた」。これは定性的な確認であり、正解文を用いた文字誤り率の測定ではない。

| 計測項目 | 結果 |
| --- | --- |
| 実時間 | 300.016秒、ブラウザー側の5分タイマーで自動停止 |
| マイク | MacBook Pro 内蔵マイクを許可ダイアログで明示選択 |
| 文字起こし | 478差分、1,097文字、最後の通知は開始300.008秒後 |
| assistant transcript / 通常 turn / エラー | すべて0 |
| 受信音声 | 計測した28,636,160サンプルすべて0、peak / RMS 0 |
| 入力の音量が閾値以上だった時間 | 190.256秒（RMS ≥0.005。発話VADではない） |
| 接続 | WebRTC / data channel / 音量計測が終盤まで稼働、受信パケット損失0 |
| 内容の保存 | 音声・会話文は検証ファイルに保存せず、画面内の会話文も終了時に消去 |

| 経過区間 | 文字起こし差分数 |
| --- | ---: |
| 0–1分 | 91 |
| 1–2分 | 115 |
| 2–3分 | 138 |
| 3–4分 | 42 |
| 4–5分・終了処理 | 92 |

最後の区間には終了時の8 ms分も含む。通知時刻はローカルで受信した相対時刻であり、発話の正確なタイムスタンプや認識遅延ではない。途中の通知の間は、本人の発話の間や処理待ちと区別できないので、通知が常に等間隔に届くとは評価しない。全5つの1分区間と終盤に入力差分が届いたことを継続の根拠にする。

### 構成・操作

`mise run real-mic` で loopback の計測ページを起動し、Chrome で表示する。①マイクを準備し、許可の選択肢で内蔵マイクと今回のみの許可を選ぶ。②開始すると既存 ChatGPT ログインの v3 / wham セッションへ接続し、接続後に300秒のタイマーが始まる。Platform API キーは child process の環境から除く。マイク切替や音声ファイルによる代用は行わない。

ブラウザーの getUserMedia と WebRTC メディアトラックで送り、AudioWorklet で入力と受信音声を計測する。受信音声は **音量計測の後** にローカルの0ゲインへ接続するため、実際に音声が生成された場合は計測に現れる。再生しないことを無発声の根拠にはしない。PCM は float、AudioContext は48 kHz、今回の Worklet 入力集計は2chだった。sample 数は Worklet の全チャネルの値の数である。

音量は0.5秒周期で集計し、ブラウザーから2秒周期で数値だけを送る。結果の browser フィールドは最後の計測時点の状態であり、終了後にマイクや接続を開いたままという意味ではない。終了時にはマイクトラック・peer・AudioContext を閉じ、画面の文字起こしを消し、Codex の realtime / process も停止する。

事前に定めた基準は `results/real-microphone-criteria.json`。300秒近くの完了、実マイクの入力、複数の1分区間と最後の1分の transcript、無発声、接続・計測の稼働を評価し、[検算結果](results/real-microphone-validation.json) は全条件を通過した。Worklet の数値計測は、無音・既知の非0サンプル・reset をオフラインでテストしてから使った。

生データは [数値だけの連続計測](results/real-microphone-listen-only.json)、[1分区間の集計](results/real-microphone-minute-summary.json)、[本人の定性的な確認](results/real-microphone-owner-feedback.json)。結果には会話文、音声、OAuth 値、デバイスID、SDP、IPを含めない。文字起こしは live DOM と上限のあるプロセス内バッファにだけ置き、ツールで検査したのも数値だけのエンドポイントである。

今回も `/transcript/done` は0件。差分を連結する使い方の検証であり、発話ごとの最終確定は別途必要。1人・1台・5分の実証を、複数話者・一昼夜・任意の入力での無発声保証へ広げない。指示依存であるという前節の制約は変わらない。

## 認証・費用・未確認範囲

- ChatGPT ログインだけの WebSocket は両版で失敗。既存の Platform API キーをプロセスへ渡すと、0.163.0 の会話モードは動作した。API キーの保存・login/start・ログアウトは実行していない。
- WebRTC は ChatGPT 認証で実際に動作した。成功条件は次節。標準の codex 接続先で失敗した試験と区別する。API キーなしという認証条件を検証したが、請求明細やプランごとの使用枠は未測定。
- Platform の短い疎通には gpt-realtime-mini と、内部設定の gpt-4o-mini-transcribe を使った。高単価の Codex モデルは呼んでいない。通常 turn の捕捉はローカル模擬サーバーだけで完結し、誤って委譲されても実モデルへ接続しないようにした。
- この試験は料金明細・使用量の請求内訳を測らない。「Codex 契約内で別料金なし」「汎用 ASR として無制限に使える」という結論は出せない。
- 公式 app-server 文書はローカル / OSS と商用・ホスト型サービスの認証の扱いを区別している。接続成功は配布・商用利用の許諾の確認ではない。製品採用時の条件は同文書と Sign in with ChatGPT を確認する。
- 実マイクは Mac の内蔵マイクで5分確認。Mac 以外の OS、マイク切替、音声出力の再生、5分を超える連続運転、並列・割り込みを伴う委譲、正解文と比較する認識精度は未検証。

## ChatGPT ログインだけの WebRTC：成功条件と原因

CLI を次のプロセス単位の設定で起動する。ユーザーの config.toml は変更しない。

```sh
codex app-server \
  -c 'experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"'
```

クライアントは `experimentalApi=true` で初期化し、`thread/realtime/start` に `version="v3"`, `outputModality="audio"`, `transport={type:"webrtc",sdp:OFFER}` を渡す。**Realtime の model は指定しない。** SDP answer は `thread/realtime/sdp` で受け取り、WebRTC peer に設定する。マイクやファイルの音はメディアトラックで送り、`appendAudio` で重ねて送らない。

実測では child process の `OPENAI_API_KEY` を除去し、`account/read` は chatgpt、接続にプロキシを使わず、CLI の OAuth 管理をそのまま利用した。ログインし直したりトークンを読み出したりしていない。

| 成功時の計測 | 値 |
| --- | --- |
| call-create の接続先 | `chatgpt.com/backend-api/wham` |
| peer / data channel | connected / open |
| 送った共有素材 | 321,984 bytes、24 kHz mono PCM16、6.708秒 |
| user の最終文字起こし | Did you bring the map? Yes, it is right here |
| assistant の最終テキスト | OK. |
| 受信したデコード済み音声 | 633 frames / 607,680 samples（無音も含む） |
| 通常の Codex turn | 0件 |
| 実時間 | 15.734秒 |

**前回失敗の主な原因は接続先の違いだった。** 標準 CLI の call-create は `/backend-api/codex/realtime/calls`、デスクトップアプリは `/backend-api/wham/realtime/calls` を使う。CLI には call-create だけを上書きする設定があり、ChatGPT 認証と sideband の接続は保持できる。

最初は codex 接続先が返した `session.model is not allowed` を文字どおりに解釈してフィールドを除く試験も行ったが、それだけでは同じエラーのままだった。model 変更、空 session、session 自体の除去、legacy query の除去も切り分けた。最終的に **要求の内容を変えず、接続先だけ wham にした比較**で HTTP 201・SDP・peer connected を確認した。その後、検証用 relay を外した直接接続で上記の音声往復を確認した。したがって「model フィールドを除けば解決する」という結論にはしない。

v1 は quicksilver=v1 ヘッダーに対してサービスが v2 を要求し、v2 は CLI が WebRTC call-create をローカルで拒否する。成功した v3 は quicksilver=v2 ヘッダーを送る。今回の成功は v3 の音声会話であり、単独 transcription や通常 turn の音声対応を示さない。

観測用 relay は127.0.0.1だけに bind し、転送先は上記2つの固定 ChatGPT パスに限定した。OAuth ヘッダーは RAM で転送し、値を記録しない。SDP、IP、call ID、全プロンプト、音声データも保存しない。探索結果は `results/webrtc-followup-*.json`、直接接続の証拠は `results/webrtc-direct-chatgpt-audio.json`。relay は成功時の必須構成ではない。

この設定は実験的な内部接続先に依存する。公式の全プラン向け保証や、外部製品へ恒久的に公開された汎用 ASR API の契約とは区別する。今回の既存 ChatGPT ログインで API キーなしの音声往復が通った、という範囲で結論を更新する。

## 再現方法

Node、Python 3.13、uv、FFmpeg と、JSON schema を生成できる Codex CLI を使う。Python の補助依存は websockets 16.0 / aiortc 1.15.0。CLI は比較対象なので旧0.159.3と安定0.163.0を pin する。

```sh
mise run prepare       # CLIをlab内へ隔離、共有素材、スキーマと実装を取得
mise run               # 保存結果の検算だけ。通信・課金なし
mise run mock          # ローカル上流だけで転送・通知・通常turnを確認
mise run gates         # 既存ChatGPTログインで実験機能/キー条件を確認
# 以下は明示的に選ぶ短い実サービス試験。OPENAI_API_KEY は環境に設定する。
LIVE_MODE=conversational mise run live-ws
LIVE_MODE=transcription mise run live-ws
TRANSCRIPTION_INTENT=1 LIVE_MODE=transcription mise run live-ws
REALTIME_VERSION=v3 mise run live-webrtc # 最初の codex 接続先の比較条件
mise run chatgpt-webrtc                  # wham への直接接続で共有音声を往復
TRANSCRIPT_ONLY_MODE=listen-only mise run transcript-only # 応答禁止、2回入力
TRANSCRIPT_ONLY_MODE=spoken-control mise run transcript-only # 音量計測の発声対照
TRANSCRIPT_ONLY_MODE=text-modality mise run transcript-only # v3 text の拒否条件
mise run real-mic                     # 実マイク用ページ。本人が開始・発話する
```

実サービスの結果は確率的であり将来のサービス更新でも変わるため、保存結果の検算と再接続を分けた。最初の WebRTC 試験は無音の合成トラック、追加の直接接続試験は共有 PCM 素材で、マイク権限は使わない。収集物にはプロトコル設定、通知、共有素材の文字起こし、音声の長さとハッシュだけを残す。API キー、OAuth トークン、SDP、IP、音声データ、全システムプロンプトは Git に入れない。

`work/` は無視対象。生成した版別スキーマの必要部分を `schemas/`、実装 commit と SHA-256 を `results/manifest.json` に記録した。前提の検証コードを他 lab から import しない。

## 一次資料

- [公式 Codex App Server](https://learn.chatgpt.com/docs/app-server): 初期化、版別 schema 生成、実験機能、認証の位置づけ。
- [公式 Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription): 一般の transcription セッションと commit。Codex が固定しているモデル・操作面とは一致しない。
- [0.163.0 core の realtime 起動・認証・model 既定値](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/core/src/realtime_conversation.rs)
- [0.163.0 上流 v2 の session 設定](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/codex-api/src/endpoint/realtime_websocket/methods_v2.rs)
- [0.163.0 WebSocket URL と音声転送](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/codex-api/src/endpoint/realtime_websocket/methods.rs)
- [0.163.0 app-server の通知変換](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/app-server/src/bespoke_event_handling.rs)
- [0.163.0 非対応モデルの音声除去](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/core/src/context_manager/normalize.rs)
