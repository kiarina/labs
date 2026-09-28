# Moving an MCP gateway from langchain-mcp-adapters (MCP 1) to MCP 2, with and without LangChain

[kimcp](https://github.com/kiarina/kimcp)（MCP サーバーを登録して、CLI からツールの一覧と実行をさせる小さなゲートウェイ）は、
`langchain-mcp-adapters` 0.3.2 が `mcp<2.0.0` に固定しているため MCP Python SDK 2 へ上がれません。上流は 2026-09-11 に保守を終え、
MCP の対応は LangChain 本体の `langchain.mcp`（`langchain[mcp]`、中身は fastmcp 4）へ移りました。

kimcp が LangChain を使っているのは、接続の保持・ツールの一覧・実行を `langchain-mcp-adapters` に任せるためだけです（LangChain を中心にした
作業用プロジェクトから切り出された名残）。ゲートウェイとしては MCP のクライアントであれば足ります。

この lab では、移行先の候補を 3 つ並べ、今の kimcp と同じ使い方のクライアントと一緒に、MCP 1 と MCP 2 のサーバーへ実際につないで比べます。

| 名前 | 依存 | 使い方 |
| --- | --- | --- |
| v1（今の kimcp） | `langchain-mcp-adapters` 0.3.2 + `mcp` 1.30.0 + `langchain-core` 1.6.5 | `MultiServerMCPClient(...).session(name)` に入ったまま `load_mcp_tools(session)` → `tool.ainvoke(args)` |
| v2（LangChain に残る） | `langchain[mcp]` 1.4.2 + `fastmcp` 4.0.10 + `mcp` 2.2.0 + `langchain-core` 1.6.5 | `fastmcp.Client` に入ったまま `as_langchain_tool(tool, client)` → `tool.ainvoke(args)`。`MCPAdapter` も別に試す |
| sdk（LangChain を外す） | `mcp` 2.2.0 だけ | `mcp.Client` の `list_tools()`・`call_tool()`。結果は MCP のまま |
| fastmcp（LangChain を外す） | `fastmcp-slim[client]` 4.0.10 だけ | `fastmcp.Client` の `list_tools()`・`call_tool_mcp()`。結果は MCP のまま |

## Purpose

1. 各クライアントで、3 つの接続方式（stdio・SSE・streamable HTTP）は動くか。MCP 1 と MCP 2 のどちらのサーバーにもつながるか
2. ツールの結果・エラー・画像・構造化出力はどういう形で返るか（kimcp の `run-tool` の出力に効く）
3. kimcp が今持っている接続設定の項目（タイムアウト、`encoding` など）は引き継げるか
4. ゲートウェイの使い方が成り立つか。接続を持ち続ける、接続・実行・切断を別々のタスク（FastAPI のリクエストごとのタスク）から行う、
   1 つの接続で同時に呼ぶ、タイムアウトの後も使い続ける、切断で stdio のサーバーが止まる
5. elicitation（ツールの実行中にサーバーが利用者へ入力を求める仕組み）はどうなるか
6. 新しくできるようになることは何か

## 条件

- サーバーは `mcp.server.fastmcp.FastMCP`（mcp 1.30.0、`v1/server.py`）と `mcp.server.mcpserver.MCPServer`（mcp 2.2.0、`v2/server.py`）。
  両方に同じツールを置いた（`add`、`pid`、`image`、`structured`、`fail`、`open_object`、`slow`、`ask`）。v2 のサーバーには、
  新しいプロトコル（2026-07-28）流の elicitation を試す `ask_modern` も置いた
- クライアント 4 × サーバー 2 × 接続方式 3 の 24 通りに、MCP 2 の 3 クライアントの `mode="legacy"`（旧来の initialize ハンドシェイクを強制する）を
  stdio と streamable HTTP で足して、36 通り
- クライアントとサーバーはそれぞれの uv 環境で動かし、同じプロセスに mcp の 2 つのメジャー版が混ざらないようにした
- 別に、PyPI の kimcp 0.1.0 を実際に起動し、stdio のサーバーの接続・実行・切断を CLI から行った（`mise run kimcp-e2e`）
- Python 3.13.12、macOS 26.6（Apple Silicon）。すべて 127.0.0.1 上

```sh
mise -C 2026/09/29/kimcp-mcp2-migration run                       # 36 通りすべて
mise -C 2026/09/29/kimcp-mcp2-migration run -- client-sdk__server-v2  # キーの一部で絞る
mise -C 2026/09/29/kimcp-mcp2-migration run kimcp-e2e             # kimcp 0.1.0 を実際に動かす
```

結果は `results/matrix.json`（絞ったときは `results/matrix.partial.json`）と `results/kimcp-0.1.0-e2e.txt` に書き出す。
このリポジトリにあるのは 2026-09-29 に実行したもの。ローカルのパスは `<lab>` に置き換えてある。

## Answer

### LangChain を外すなら、`mcp`（SDK）だけで足りる

| | v2（LangChain） | sdk | fastmcp |
| --- | --- | --- | --- |
| パッケージ数 / `.venv` | 91 / 93 MB | **28 / 28 MB** | 51 / 49 MB |
| 3 方式 × MCP 1・2 のサーバー | すべて動く | すべて動く | すべて動く |
| SSE で新しいプロトコル（2026-07-28） | 乗らない（2025-11-25） | **乗る** | 乗らない（2025-11-25） |
| kimcp 0.1.0 の接続設定の項目 | 一部なくなる | **すべて引き継げる** | 一部なくなる |
| 新しいプロトコルの HTTP で、タイムアウトの後 | 接続が切れ、切断も失敗 | **使い続けられ、切断もできる** | 接続が切れ、切断も失敗 |
| 別のタスクからの切断 | （試していない） | 失敗する。持ち主のタスクを置けば通る | そのまま通る |
| 切断で stdio のサーバーが止まるか | 止まらない（`transport.close()` が要る） | 止まる | 止まらない（`keep_alive=False` か `transport.close()` が要る） |
| 1 つの接続で 5 本同時に 0.5 秒のツール | （試していない） | 505〜512 ms | 506〜514 ms |
| API の安定性 | `langchain.mcp` はベータ | MCP の公式 SDK | 安定版 |

- **sdk は、kimcp 0.1.0 の接続設定をすべてそのまま渡せました。** stdio の `command`・`args`・`env`・`cwd`・`encoding`、SSE の `url`・`headers`・
  `timeout`・`sse_read_timeout`（`sse_client` の引数）、streamable HTTP の `headers`・`timeout`・`sse_read_timeout`（`httpx2.AsyncClient` に
  `Timeout(timeout, read=sse_read_timeout)` として渡す）と `terminate_on_close`。すべて指定した接続で `add` が通りました（sdk の全 10 通り）。
  `session_kwargs` は `Client` の引数（`read_timeout_seconds`、`elicitation_callback` など）に当たります
- fastmcp の transport には、SSE の `timeout`、streamable HTTP の `timeout`・`sse_read_timeout`・`terminate_on_close`、stdio の `encoding` に当たる
  引数がありません
- **新しいプロトコルの streamable HTTP でタイムアウトの後に接続が切れる件は、fastmcp のクライアントで起きます。** v2（fastmcp を使う）と fastmcp は、
  1 秒のタイムアウトで 2 秒のツールを呼んだ後、次の `add` が `RuntimeError: Client is not connected` になり、切断は `httpx2.ReadTimeout` で失敗しました
  （v2 は 3 回とも同じ）。sdk は同じ条件で、タイムアウトの後の `add` も切断も通りました。`mode="legacy"` ではどれも起きません
- **sdk の `mcp.Client` は、入ったタスクで出る必要があります。** 接続・実行・切断を別々のタスクで行うと、切断が
  `RuntimeError: Attempted to exit cancel scope in a different task than it was entered in` になりました（sdk の全 10 通り）。接続を持ち続ける
  専用のタスクを 1 本置き（`sdk/client.py` の `OwnedSession`）、切断ではそのタスクに終わるよう知らせる形にすると、全 10 通りで接続・実行・切断が通り、
  stdio のサーバーも止まりました。fastmcp は接続を内部の別タスクで持つので、そのままで通りました

### 今の kimcp にも同じ問題がある

- **kimcp 0.1.0 は、切断のたびに失敗しています。** 実際に `kimcp serve` を起動して stdio のサーバーをつなぎ、`disconnect` すると、CLI は
  `"disconnected": true` を返しますが、ゲートウェイのログには毎回 `Failed to close session probe-v1: Attempted to exit cancel scope in a different task
  than it was entered in` が出ました（v1・v2 のサーバーとも）。1 秒後には stdio のサーバーのプロセスは無くなっていました
- 同じことは v1 のクライアントでも起き、別のタスクからの切断は全 6 通りで `RuntimeError` でした。接続は connect のリクエストのタスクで入り、
  切断は disconnect のリクエストのタスクで出るためです。移行先にかかわらず、接続を持ち主のタスクに持たせる形へ直す必要があります
- v1 のクライアントで MCP 2 の stdio サーバーを使うと、タイムアウトの後の切断が `ExceptionGroup`（中身は `anyio.BrokenResourceError`）で失敗しました（3 回とも同じ）

### 結果の形

- LangChain を通すと（v1・v2）、`ainvoke` の戻り値は LangChain の content block のリストになり、`'id': 'lc_...'` が付きます。
  ツールの失敗（`isError=True`）はエラーの文面として返り、失敗したかどうかは文面からしか分かりません。kimcp 0.1.0 の `run-tool` もこの形を返しています
- sdk と fastmcp（`call_tool_mcp`）は MCP の `CallToolResult` をそのまま返します。`content`、`structuredContent`、`isError`、新しいプロトコルでは
  `_meta` にサーバーの名前と版が入ります。失敗は `"isError": true` で分かります
- LangChain を外すと `run-tool` の出力の形は変わります
- ツールの引数の schema は、どのクライアントでもサーバーが出したまま取れました（開いたオブジェクトは `additionalProperties: true`）。
  kimcp 0.1.0 は LLM のプロバイダー向けに `additionalProperties` を書き換えていますが、ゲートウェイには要りません

### elicitation

- 旧来のプロトコル（2025-11-25）：どのクライアントも、ハンドラーが無ければサーバーに「非対応」と返り、ハンドラーを渡せば答えられた
- 新しいプロトコル（2026-07-28）：サーバーが `ctx.elicit()`（サーバーから呼びかける旧来の方法）を使うと、ハンドラーがあっても
  `Cannot send 'elicitation/create': this transport context has no back-channel` で失敗した。サーバーが `InputRequiredResult`
  （入力の要求を結果として返し、クライアントが答えを付けて呼び直す新しい方法）を返す場合は、sdk・fastmcp・v2 のどれもハンドラーで答えられた
- `MCPAdapter` の既定は、elicitation を LangGraph の interrupt として扱う。LangGraph の外で `InputRequiredResult` が返ると
  `KeyError: '__pregel_scratchpad'` になった
- `ask_modern` は、旧来のプロトコルでつながると `Handler returned an invalid result` になった。2 つのプロトコルの両方に対応するのはサーバー側の責任

### サーバー側の違い（クライアントと関係ない）

- MCP 2 のサーバーは、ツール内の例外の文面をクライアントへ返しません。v1 のサーバーは `Error executing tool fail: boom from tool`、
  v2 のサーバーは `Error executing tool fail` だけ。v2 のサーバーの失敗は約 150 ms かかった（サーバーが traceback をログに出している）

### 新しくできるようになること

- MCP 2 の新しいプロトコル（2026-07-28）で MCP 2 のサーバーと話せる。セッションを持たない HTTP、`server/discover`、サーバーの TTL に従う
  一覧のキャッシュ（`list_tools(cache_mode=...)`）
- `list_resources`・`list_prompts` など、ツール以外の MCP の機能（新旧のどちらのサーバーでも応答した）
- 1 つの接続での同時実行（5 本の 0.5 秒のツールが約 0.51 秒で終わった）
- elicitation に答えるハンドラー（kimcp 0.1.0 は持っていない）
- 認証：sdk は `httpx2.Auth`（`sse_client(auth=...)`、`httpx2.AsyncClient(auth=...)`）と OAuth のクライアントを持つ。fastmcp は
  `Client(auth="oauth")` や bearer トークンの文字列で、より手短に書ける

### 確かめていないこと

- 認証付きのサーバー、TLS の検証（MCP 2 は certifi ではなく OS の信頼ストアを使う）
- Windows、Python 3.12
- 長時間の接続、サーバーの再起動からの復帰、多数の同時呼び出し
- v2（LangChain）での別タスクからの切断と同時実行
- fastmcp のタイムアウトの件が、上流の不具合か仕様か

## ファイル

- `v1/` `v2/` `sdk/` `fastmcp/` — それぞれの uv 環境とクライアント（`client.py`）。`v1/` `v2/` にはテスト用サーバー（`server.py`）もある
- `run_matrix.py` — 36 通りを回して `results/matrix.json` に書く（標準ライブラリだけ）
- `.mise/tasks/kimcp-e2e` — PyPI の kimcp 0.1.0 を起動して CLI から試し、`results/kimcp-0.1.0-e2e.txt` に書く
- `results/` — 2026-09-29 の実行結果
