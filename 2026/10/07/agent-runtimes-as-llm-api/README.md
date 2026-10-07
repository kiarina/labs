# Using codex app-server and the Claude Agent SDK like a stateless LLM API, with the history passed as XML

`codex app-server` と Claude Agent SDK を、サブスクのまま「履歴を自分で持つ LLM API」の代わりに使えるかを確かめます。
毎回新しいセッションを作り、それまでの会話を XML にまとめた 1 通のメッセージを送ります。そのうえで、API に履歴を渡したときと同じように
正しいツールの呼び出しとメッセージが返るかを見ます。トークンの消費が大きいので、本番は Codex と Claude を **1 回ずつ**だけ撃ちました。

前提となる lab:
- [codex app-server で作った Codex アプリの写し](../../01/flutter-codex-app-server/README.md)
- [同じ機能を Claude Agent SDK とサブスクで作ったもの](../../05/flutter-claude-agent-sdk/README.md)
- [両方をツールとして使う司令塔](../../06/flutter-agent-orchestrator/README.md)

## Purpose

1. エージェントとしての前提（組み込みの指示・ツール・環境の説明）をどこまで外し、API に近い形で 1 回のリクエストにできるか
2. 約 3.5 万トークンの履歴を XML で渡したとき、履歴の中で変わった事実を追って、正しい引数でツールを呼べるか（呼び出しを文字で書いてしまわないか）
3. トークン・時間・利用枠がどれだけかかるか

## Answer

- **どちらも 13 項目すべて通った。** 履歴の途中で変わった日付（16 日 → 23 日）・時間（19:00 → 19:30）・参加者（田中さんが抜けて佐藤さんが加わる）を正しく追い、
  `create_event` → `send_message` の順にツールを本当に呼び（文字で書かず）、最後にユーザーへ短く報告した。組み込みのツールは使わなかった
- **API に近い形にできた。** モデルへ送られる中身を、こちらの指示・こちらのツール・履歴だけにできた（下の「送られた中身」）。ただし Codex は設定ではなく、自前のモデル表を渡す必要があった
- 1 回あたり: 起動から最初のツール呼び出しまで 7〜8 秒、終わるまで 15〜17 秒。ツールを 2 回呼ぶので、モデルへは 3 回送られる（履歴は毎回入れ直されるが、2 回目以降はキャッシュが効いた）

| | Codex | Claude |
| --- | --- | --- |
| モデル | gpt-6.1-sol（推論 low。普段の既定） | claude-opus-5-5（effort medium、adaptive thinking） |
| 判定 | 13/13 | 13/13 |
| 最初のツール呼び出し / 全体 | 8.2 秒 / 15.2 秒 | 7.0 秒 / 16.6 秒 |
| 入力トークン（3 回の合計） | 107,261（うちキャッシュ 71,040） | 90,719（キャッシュの書き込み 45,919・読み出し 44,796） |
| 出力トークン | 357 | 1,608（うち思考 304） |
| 1 回目の入力 | 約 35,600 | 約 44,800 |
| 利用枠 | 週の 72% のまま（整数でしか見えない） | 5 時間枠 27%・週 32%（撃つ前の値は取れない） |
| API 換算 | — | $0.41（SDK の `total_cost_usd`） |

- 1 回目の入力トークンは、空撃ちで見た中身（`tiktoken` の o200k で約 3.5 万）とほぼ合う。送信先の向こうで大きな指示が足されている形跡はない
- **Claude は頼まれていないことも言った。** 履歴の中の自分（ai_message）の過去の要約が、議事録に無いことを書いていたと気づき、最後のメッセージで訂正した
  （例: 「リリースは 10/20 に延期」。これは題材を作ったときの手落ちで、議事録の本文と ai_message の要約が食い違っていた）。Codex は求められたことだけを返した。
  API の代わりに使うなら、Claude は履歴の矛盾にも口を出す前提で、応答の長さを見込んでおく

## How it works

```text
src/fixture.ts   履歴（XML）と最後の指示、正解を作る（乱数は固定）
src/tools.ts     アプリのツール 7 つ（JSON Schema）と、呼ばれたときに返す仮の結果、system prompt
src/codex.ts     codex app-server に 1 回送る（--mock で偽サーバーへ）
src/claude.ts    Agent SDK で 1 回送る（--mock で偽サーバーへ）
src/mock.ts      偽サーバー：届いたリクエストを記録してエラーを返す
src/grade.ts     ツールの呼び出しと最後のメッセージを判定する
```

### 題材

- 履歴は `<messages>` の中に `<human_message>`・`<ai_message>`・`<tool_call>`・`<tool_result>` を日時付きで並べ、その後ろに今回の指示を置く
- 筋書き: アシスタントがチームの打ち上げを 5 日がかりで決める。日付・時間・参加者が途中で変わり、外した店や来月の候補の店も残る。
  議事録の要約・天気・1on1 の登録など関係のない用件と、長い `tool_result` で量を増やした
- 最後の指示: 「`<messages>` の内容から、打ち上げの予定を予定表に登録し、参加者全員に案内のメッセージを送ってください」
- 判定（13 項目）: ツールを本当に呼んだか／組み込みのツールを使っていないか／`create_event` が `2026-10-23T19:30`・120 分・`plc_0417`・9 名ちょうどか／
  `send_message` が本人を除く 8 名（本人は任意）へ日時と店を書いて送ったか／古い事実が混ざっていないか／最後にユーザーへ返したか

### 偽サーバーで送られる中身を確かめる（トークンを使わない）

どちらにも、モデルの送信先を差し替える正式な設定がある（プロキシやゲートウェイを挟むためのもの）。`--mock` ではそれを手元の偽サーバーに向け、届いたリクエストを記録してエラーを返す。
本番（`--mock` なし）では使わず、普段のログインのまま送る。

- Codex: `thread/start` でモデル提供元 `mock`（`model_providers`、`wire_api = "responses"`）を足して `modelProvider: "mock"`
- Claude: 起動する Claude Code にだけ `ANTHROPIC_BASE_URL` と仮の API キーを渡す

### 送られた中身

| | Codex（既定） | Codex（この lab の設定） | Claude（この lab の設定） |
| --- | --- | --- | --- |
| 指示 | こちらの指示 + スキル一覧 + サブエージェントの役割 + 環境の説明 | こちらの指示だけ | こちらの指示 + SDK の名乗り 1 行 + 環境の説明（約 900 文字） |
| ツール | `exec`（JS のセル）の中にこちらのツールが入る。サブエージェントのツール、MCP サーバー | こちらの 7 つ + `request_user_input` | こちらの 7 つ（`mcp__app__` 付き） |
| 余計な送信 | — | — | 既定ではセッションの名前付けのために全文がもう一度送られる（`title` で止まる） |

記録: `results/codex-capture-code-mode.json`（機能を切ってもモデル表は既定のまま）、`results/codex-capture-direct.json`、`results/claude-capture.json`

## Findings

- **Codex の新しいモデルは「ツールは JS の中から呼ぶ」に固定されている。** `~/.codex/models_cache.json` のモデル表で `tool_mode: "code_mode_only"` になっていて、
  アプリのツールも `exec` の中の `tools.create_event(...)` としてしか見えない。機能の設定（`features.*`）でも `thread/start` の `config` でも外れない。
  自前のモデル表（そのモデルの項目を写して `tool_mode`・`multi_agent_version`・`apply_patch_tool_type` を null にしたもの）を
  `codex app-server -c model_catalog_json=<path>` で渡すと、ツールが直接の function として渡る。モデル表は Codex の更新で変わりうる
- **Codex の設定はプロセスの起動時に渡す。** `thread/start` の `config` に書いた `features`・`model_catalog_json` は効かなかった。`codex app-server --disable <feature>` と `-c` で渡す
- Codex で外したもの: `include_environment_context`・`include_permissions_instructions`・`include_apps_instructions`・`include_collaboration_mode_instructions`・
  `skills.include_instructions` を false、`config.toml` の MCP サーバーを `mcp_servers.<name>.enabled=false`、シェル・ブラウザ・画像生成などの機能を `--disable`。
  `baseInstructions` は `instructions` ではなく developer のメッセージとして送られた
- Claude は `systemPrompt`（文字列）・`tools: []`・`settingSources: []`・`strictMcpConfig`・`persistSession: false`・`title` で、ほぼ API と同じ形になる。
  ツール名に `mcp__app__` が付くのと、環境の説明（作業ディレクトリ・OS・モデル名・日付）が user の後ろに足されるのは残る
- Claude Code はプロンプトのキャッシュに 1 時間の TTL を使っていた（`ephemeral_1h_input_tokens`）。同じ履歴の先頭を持つリクエストを 1 時間以内に続けて送れば、毎回新しいセッションでもキャッシュが効くはず（未検証）
- **未検証:** 1 回ずつなので、ばらつき・キャッシュの効き方・利用枠の減り方（Codex は整数でしか見えず、72% のまま動かなかった）は分からない

## How to run

前提: `codex login` と `claude auth login`（サブスク）、mise、Node 22。

```bash
mise run        # 型検査と、偽サーバーへの空撃ち（トークンを使わない）
mise run run    # 本番を 1 回ずつ撃って判定する（サブスクの利用枠を使う）
```

`results/codex.json`・`results/claude.json` が実行の記録、`results/*-grade.json` が判定です。

## Environment

- macOS 27.0.1、MacBook Pro M1 Max
- Node 22.22
- codex-cli 0.159.3、`@anthropic-ai/claude-agent-sdk` 0.3.292（同梱の Claude Code 2.1.292）、zod 4.6.5
- ChatGPT（Codex、Pro Lite）と Claude Max のサブスク
- 2026-10-07 に実行
