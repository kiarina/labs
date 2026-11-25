# Codex の通話を gpt-live-1.1-codex で始められるか（0.170.0 の model 指定と 0.172.0 の既定）

Codex の app-server の通話（`thread/realtime/start`、`version: v3`、WebRTC）は、これまで `gpt-live-1-codex` で動いていた。
新しい `gpt-live-1.1-codex` で始められるかを、ChatGPT のログインで確かめた（2026-11-25）。

## 方法

`probe.py` が `codex app-server` を stdio で起こし、aiortc で WebRTC の通話を張る（マイクは無音）。
`thread/realtime/appendText`（`role: user`）で「『はい』とだけ短く答えてください。」と 1 回だけ送り、assistant の文字起こしと、
データチャネル `oai-events` に届いた `session.started` を `results/` に残す。API キーは使わない（`OPENAI_API_KEY` を外す）。

```bash
uv venv .venv && uv pip install --python .venv aiortc   # aiortc 1.16.0
npm i --prefix work/cli @openai/codex@0.172.0
CODEX=codex .venv/bin/python probe.py v0170-model-1.1 gpt-live-1.1-codex     # 0.170.0 に model を渡す
CODEX=codex .venv/bin/python probe.py v0170-model-bogus gpt-live-9-codex-nonexistent
CODEX=work/cli/node_modules/.bin/codex .venv/bin/python probe.py v0172-default ""
```

## 結果

| 条件 | Codex | 渡した model | つながるまで | 返事 | 返事まで |
|---|---|---|---|---|---|
| `v0170-model-1.1` | 0.170.0 | `gpt-live-1.1-codex` | 3.2 s | はい。 | 3.1 s |
| `v0170-model-bogus` | 0.170.0 | `gpt-live-9-codex-nonexistent` | 1.6 s | はい。 | 2.9 s |
| `v0172-default` | 0.172.0 | （なし。既定） | 5.4 s | はい。 | 3.4 s |

- **0.172.0 は既定で `gpt-live-1.1-codex` を頼む。** ソースの `DEFAULT_FRAMELESS_REALTIME_MODEL` が 0.170.0 の `gpt-live-1-codex` から
  変わった（openai/codex#61259「Update realtime model and honor provider-specific voice defaults」、2026-11-13）
- **0.170.0 でも `thread/realtime/start` の `model`（または config の `experimental_realtime_ws_model`）で頼める。** model は
  通話を作る要求の `session.model` に入る
- **ただし、実際にどのモデルが答えたかは外から確かめられない。** 存在しない名前でも同じようにつながって答えた。
  `session.started` には `id`・`status`・`expires_at` だけでモデル名は無い。ChatGPT の経路のバックエンドが、知らない名前を
  黙って既定に置き換えているか、名前を見ていないと考えられる。品質や速さの差は 1 回の短い返事では分からない

## 次の版で変わること（未リリース、main）

openai/codex#63810「Use ChatGPT account preferences for Codex voice chat」（2026-11-25、0.172.0 には未収録）は、
`thread/realtime/start` から声の指定（`voice`）を外し、ChatGPT のアカウントに保存した声（`account/voiceSettings/read`・`write`）を使う形に変える。
声を通話ごとに選んで渡しているクライアントは、この版から声を選べなくなる。

## 関連

- [flutter-gpt-live-codex-meanvc2-playout](../../../10/20/flutter-gpt-live-codex-meanvc2-playout/) — gpt-live-1-codex の通話の受信音を加工した lab
