# What codex app-server sends to a custom Responses API provider, and running OpenAI and a custom provider side by side

自前の推論サーバー（kiapi）を Codex のモデルの送り先にする前に、Codex が Responses API に何を送り、どんな返事なら受け付けるかを、
Responses API のふりをする偽サーバーで確かめます。あわせて、1 つの `codex app-server` で OpenAI のスレッドと自前の送り先のスレッドを同時に走らせられるかを確かめます。

前提となる lab:
- [codex app-server と Claude Agent SDK を状態のない LLM API のように使う](../../07/agent-runtimes-as-llm-api/README.md)（送り先の差し替えとモデル表の書き換えを最初に確かめた）
- [Codex と Claude のスレッドをツールとして動かす司令塔](../../06/flutter-agent-orchestrator/README.md)（ここに 3 つ目のワーカーとして並べるのが目的）

## Purpose

1. 自前の送り先へ、Codex は何を送るか（エンドポイント、ヘッダー、本文の項目、ツール、履歴の形）
2. Codex は、どんな形のストリームを受け付けて、ツールの往復と最後の回答まで進むか
3. 1 つの app-server で、OpenAI のスレッドと自前の送り先のスレッドを同時に走らせられるか

## Answer

- **自前の送り先へは `POST {base_url}/responses` だけが届く。** `/models` などは呼ばれない。`stream: true`・`store: false` で、会話の状態はサーバーに持たせず、
  毎回それまでの履歴を全部 `input` に入れて送る。ChatGPT のログインの `Authorization` は送られない
- **下に書く最小のストリームで、Codex はツールの往復から最後の回答まで進んだ。** 偽サーバーが `exec_command` の呼び出しを返すと、Codex は
  `echo hello-from-tool` を実際に実行し、結果を `function_call_output` にして次の依頼で送り、最後の `message` を回答として受け取った（2 ターン、どちらも completed）
- **1 つの app-server で同時に走らせられる。** OpenAI のスレッド（`gpt-5.6-luna`、「OK」と答えた）と偽サーバーのスレッドを同時に始め、両方 completed。
  偽サーバーに届いたのは自分のスレッドの依頼 1 件だけだった
- **ただし、モデル表を書き換えないと送り方が変わる。** OpenAI の既定のモデル表のままのスレッドでは、Codex は「responses lite」の形で送った:
  `instructions` と `tools` が空で、ツールは `input` の中の `additional_tools` の項目に入り、シェルなどは JS の `exec`（`custom` のツール）の中から呼ぶ形になる。
  自前のモデル表で `tool_mode`・`use_responses_lite` を外すと、普通の function のツールとして届いた。モデル表と機能の切り替えはプロセスの起動時にしか渡せないので、
  **自前の送り先用の Codex は別のプロセス（別の `CODEX_HOME`）にする**のが扱いやすい

## Method

`probe.py` が、Responses API のふりをする偽サーバー（台本どおりに返す）を立て、Python の SDK（`openai-codex`）で `codex app-server` を動かす。

- 台本: そのターンの最初の依頼には、送られたツールの中のシェル（`exec_command` など）の呼び出しを返す。最後の項目がツールの結果の依頼には、`SCRIPTED-DONE` の回答を返す
- `tuned`: 自前の送り先用に調整した app-server（トークンを使わない）
  - 空の `CODEX_HOME`（ユーザーの MCP サーバー・スキル・ログインを持ち込まない）
  - `-c model_providers.kiapi={…, wire_api="responses"}`・`model_provider="kiapi"`・`model="kiapi-local"`
  - `-c model_catalog_json=…`: OpenAI の `gpt-5.6-luna` の項目を写し、slug を `kiapi-local` に変え、`tool_mode`・`multi_agent_version`・`apply_patch_tool_type` を null、
    `use_responses_lite` を false などにしたもの
  - `features.*=false`（code mode・multi agent・apps・plugins・画像生成・computer use・ブラウザ・goals・memories など）、`web_search="disabled"`
  - 1 ターン目「`echo hello-from-tool` を実行して」、2 ターン目「ありがとう」
- `mixed`: ユーザーの普段の設定の app-server 1 つに、OpenAI のスレッドと、`thread/start` の `config` で偽サーバーを `model_providers` に足して
  `modelProvider` で指したスレッドを立て、同時に「Reply with exactly: OK」を送る（OpenAI へは極小の依頼が 1 回。サブスクを使う）

## Results

記録: `results/tuned.json`、`results/mixed.json`（要約。生の依頼は `results/*-requests.json` に出るが、Codex の指示の全文を含むので commit しない）

### 届いた依頼（`tuned`）

ヘッダー: `accept: text/event-stream`、`content-type: application/json`、`originator`、`user-agent`、`session-id`・`thread-id`・`x-client-request-id`、
`x-codex-turn-metadata`・`x-codex-window-id`・`x-codex-beta-features: remote_compaction_v2`。`authorization` は無い。

本文:

| 項目 | 値 |
| --- | --- |
| `model` | `kiapi-local`（モデル表の slug がそのまま来る） |
| `instructions` | Codex の指示（17,730 文字。「You are Codex, an agent based on GPT-5…」） |
| `input` | 履歴の全部（下） |
| `tools` | function 4 つ: `exec_command`（`cmd`・`workdir`・`yield_time_ms` など 10 項目）、`write_stdin`、`request_user_input`、`view_image`。`strict: false` |
| `tool_choice` / `parallel_tool_calls` | `auto` / `true` |
| `stream` / `store` | `true` / `false` |
| `reasoning` | `{"effort": "medium"}` |
| `include` | `["reasoning.encrypted_content"]` |
| `text` | `{"verbosity": "low"}` |
| `prompt_cache_key` | スレッドの ID |
| `client_metadata` | ターンの ID など |

`input` の並び（2 ターン目の 2 回目の依頼）:

```text
message(developer: input_text ×2)   … スキルの一覧・権限の説明
message(user: input_text)           … <environment_context>（cwd・shell・日付・タイムゾーン・書き込める範囲）
message(user: input_text)           … 1 ターン目の依頼
function_call(exec_command)         … 偽サーバーが返した呼び出しがそのまま戻る（id・call_id・arguments）
function_call_output                … call_id と output（"Chunk ID…\nProcess exited with code 0\n…Output:\nhello-from-tool\n"）
message(assistant: output_text)     … 1 ターン目の回答
message(user: input_text)           … 2 ターン目の依頼
function_call / function_call_output
```

- ファイルを書き換えるツール（`apply_patch`）は来なかった。モデル表の `apply_patch_tool_type` は `freeform`（`custom` のツール。文法で書く形）か null しか受け付けず、
  null にすると無くなる。ファイルの編集は `exec_command` のシェルで行うことになる
- 項目には `id`（`fco_…` など）が付いてくる。サーバーは知らない項目を無視してよい

### 受け付けられた返事

`text/event-stream` で、次のイベントを順に返した:

```text
response.created            {response: {id, object: "response", status: "in_progress", output: []}}
response.output_item.added  {output_index, item}
response.output_text.delta  {item_id, output_index, content_index, delta}     … message のときだけ
response.output_item.done   {output_index, item}
response.completed          {response: {id, status: "completed", output, usage}}
```

- `item` は `{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text"}]}` か
  `{"type": "function_call", "call_id", "name", "arguments"}`（`arguments` は JSON の文字列）
- `usage` は `input_tokens`・`input_tokens_details.cached_tokens`・`output_tokens`・`output_tokens_details.reasoning_tokens`・`total_tokens`
- reasoning の項目は返していない（返さなくても進んだ）

### 1 つのプロセスで同時に（`mixed`）

| スレッド | 送り先 | 結果 | 完了まで |
| --- | --- | --- | --- |
| OpenAI | ChatGPT のログイン | 「OK」、completed | 3.1 秒 |
| 偽サーバー | `thread/start` の `config` で足した provider | 「SCRIPTED-DONE」、completed | 1.5 秒 |

偽サーバーに届いた依頼は 1 件で、`authorization` は無く、送り方は responses lite（`instructions`・`tools` が空、`input` の先頭が `additional_tools`）だった。

## Findings

- **モデル表の設定が、送り方そのものを変える。** `use_responses_lite: true`・`tool_mode: "code_mode_only"` のモデルは、ツールを `additional_tools` の項目と
  JS の `exec` で送る。自前の送り先でこれを受けるには、その形まで実装することになる。普通の Responses API の形で受けるなら、自前のモデル表が要る
- モデル表は `-c model_catalog_json` で起動時に渡し、プロセス全体に効く（前の lab で `thread/start` の `config` では効かないと確かめた）。
  1 つのプロセスに OpenAI のモデルと自前のモデルを両方載せることもできそうだが、OpenAI のモデル表を手元の写しで固定することになり、機能の切り替えや
  `CODEX_HOME`（スキル・MCP・ログイン）も共有になる。分けるほうが扱いやすい
- モデル表の項目は型が厳しい。`apply_patch_tool_type: "function"` は拒否され（`freeform` か null だけ）、`web_search_tool_type`・`default_reasoning_level` などを null にすると
  読み込みで落ちた。写した項目から変えるのは最小限にする
- ユーザーの `~/.codex/config.toml` の MCP サーバーを `-c mcp_servers.<name>.enabled=false` で止めようとすると、この版では `node_repl`（ChatGPT アプリが書き足す項目）で
  「invalid transport」と落ちた。空の `CODEX_HOME` にして持ち込まないほうが確実
- 空の `CODEX_HOME` でも、Codex に組み込みのスキル（imagegen など）の一覧は `developer` の項目に入る

## Limitations

- 偽サーバーは台本どおりに返すだけで、モデルの賢さは測っていない。kiapi のモデル（Qwen）でこなせるかは、kiapi に Responses API を足した後の lab で確かめる
- reasoning の項目、画像の入力、`write_stdin`・`request_user_input` の往復、履歴の圧縮（`remote_compaction_v2`）は試していない
- ストリームを 1 回で書き切る返し方だけを試した。少しずつ流す返し方は kiapi の実装で確かめる

## How to run

前提: `codex login`（`mixed` だけ使う）、`uv`、mise。

```bash
mise run          # tuned（トークンを使わない）
mise run mixed    # OpenAI へ極小の依頼が 1 回（サブスク）
```

## Environment

- macOS 27.0.1、Mac Studio M4 Max 128GB
- `openai-codex` 0.160.1（同梱の codex 0.161.0。`user-agent` の版）、Python 3.12
- 実行日: 2026-10-08
