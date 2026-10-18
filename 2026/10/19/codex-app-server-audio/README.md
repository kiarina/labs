# Codex app-server の音声 API と文字起こしの境界

**ChatGPT ログインだけで WebRTC の音声送信・文字起こし・応答音声の受信まで確認できた。CLI 0.163.0 では、音声セッションを作る接続先を `https://chatgpt.com/backend-api/wham` に設定し、v3 / audio / WebRTC を使う。Platform API キーと中継プロキシは不要だった。** 通常の Codex turn への音声入力や、単独の transcription モードとは別の経路である。今回のアカウントでの疎通を示すもので、全プラン・料金・製品配布条件を保証しない。

2026-10-19、macOS 27.0.1 / arm64 で検証。既存 CLI 0.159.3 と、lab 内だけに入れた最新安定版 0.163.0 を比較した。WebRTC の追加検証も同じ0.163.0で実施し、デスクトップアプリの接続先を読み取りで照合した。グローバル CLI、ログイン、製品コード、ユーザーの設定ファイルは変更していない。録音は行わず、共有テスト素材だけを送信した。

前提の [司令塔と app-server の lab](../08/flutter-agent-orchestrator-kiapi/README.md) とは独立した小さい Python クライアントを使う。

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

## 認証・費用・未確認範囲

- ChatGPT ログインだけの WebSocket は両版で失敗。既存の Platform API キーをプロセスへ渡すと、0.163.0 の会話モードは動作した。API キーの保存・login/start・ログアウトは実行していない。
- WebRTC は ChatGPT 認証で実際に動作した。成功条件は次節。標準の codex 接続先で失敗した試験と区別する。API キーなしという認証条件を検証したが、請求明細やプランごとの使用枠は未測定。
- Platform の短い疎通には gpt-realtime-mini と、内部設定の gpt-4o-mini-transcribe を使った。高単価の Codex モデルは呼んでいない。通常 turn の捕捉はローカル模擬サーバーだけで完結し、誤って委譲されても実モデルへ接続しないようにした。
- この試験は料金明細・使用量の請求内訳を測らない。「Codex 契約内で別料金なし」「汎用 ASR として無制限に使える」という結論は出せない。
- 公式 app-server 文書はローカル / OSS と商用・ホスト型サービスの認証の扱いを区別している。接続成功は配布・商用利用の許諾の確認ではない。製品採用時の条件は同文書と Sign in with ChatGPT を確認する。
- Mac 以外の OS、実マイク、マイク切替、音声出力の再生、WebRTC の長時間運転、委譲往復、認識精度と長時間運転は未検証。

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
