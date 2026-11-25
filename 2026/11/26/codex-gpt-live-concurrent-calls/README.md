# gpt-live-1.1-codex の通話を同時にいくつ張れるか（1・2・4 本、プロセス別と thread 別）

Codex の app-server の通話（`thread/realtime/start`、`version: v3`、WebRTC）を、同じ ChatGPT のログインで同時に何本張れるかを確かめた（2026-11-26）。
Codex 0.172.0 の既定のモデル（`gpt-live-1.1-codex` を頼む）を使い、4 本まで試した。

## 方法

`probe.py` が全部の通話を同時に始め（aiortc、マイクは無音）、つながった通話それぞれに別の単語
（りんご・みかん・ぶどう・もも）を「『〇〇』とだけ答えてください。」と `thread/realtime/appendText` で送る。
これを 2 回くり返し、返事に自分の単語が入っているかで、返事が別の通話へ混ざっていないかを見る。API キーは使わない（`OPENAI_API_KEY` を外す）。
接続 ID・thread ID・SDP は保存しない。

- `process` — `codex app-server` を N 個起こし、それぞれ 1 thread・1 通話
- `thread` — `codex app-server` を 1 個起こし、その中で N thread・各 1 通話

```bash
uv venv .venv && uv pip install --python .venv aiortc==1.16.0
.venv/bin/python probe.py process 1
.venv/bin/python probe.py process 2
.venv/bin/python probe.py process 4
.venv/bin/python probe.py thread 1
.venv/bin/python probe.py thread 2
.venv/bin/python probe.py thread 4
```

## 結果

条件ごとに 1 回ずつ流した。Codex 0.172.0、aiortc 1.16.0、macOS arm64。

| 条件 | つながった | 2 回とも自分の単語で答えた | つながるまで | 返事まで |
|---|---|---|---|---|
| `process-1` | 1 / 1 | 1 | 2.7 s | 3.0〜3.7 s |
| `process-2` | 2 / 2 | 2 | 1.8〜3.0 s | 2.8〜3.3 s |
| `process-4` | 4 / 4 | 4 | 2.0〜2.4 s | 2.9〜3.3 s |
| `thread-1` | 1 / 1 | 1 | 1.8 s | 2.9 s |
| `thread-2` | 2 / 2 | 2 | 2.1〜2.2 s | 2.9〜3.0 s |
| `thread-4` | 4 / 4 | 4 | 2.2〜2.6 s | 2.7〜3.1 s |

- **同じ ChatGPT のログインで、4 本の通話を同時に張れた。** プロセスを分けても、1 つの app-server の中で thread を分けても同じ。
  エラー（`thread/realtime/error`）は 0
- **返事は混ざらなかった。** 全 24 回の返事がそれぞれ自分の通話の単語だった
- **本数を増やしても遅くならなかった。** 返事までは 1 本でも 4 本でも約 3 秒
- 5 本以上の上限、長時間の同時通話、音声を流し続けたときの負荷は試していない

## 限界

[前の lab](../../25/codex-gpt-live-1-1/) で分かったとおり、ChatGPT の経路では実際にどのモデルが答えたかを外から確かめられない
（存在しない名前でもつながる。`session.started` にモデル名が無い）。この結果は「`gpt-live-1.1-codex` を頼む既定のまま、4 本同時に張れた」という意味で、
答えたのが 1.1 であることまでは示していない。

## 関連

- [codex-gpt-live-1-1](../../25/codex-gpt-live-1-1/) — 1 本の通話を gpt-live-1.1-codex で始められるか
- [codex-app-server-audio の 2 本同時接続](../../../10/19/codex-app-server-audio/TWO_CONNECTIONS.md) — gpt-live-1-codex（Codex 0.163.0）で 2 本を同時に保ち交互に使った
