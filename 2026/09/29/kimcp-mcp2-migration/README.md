# Moving an MCP gateway from langchain-mcp-adapters (MCP 1) to langchain.mcp (MCP 2)

[kimcp](https://github.com/kiarina/kimcp)（MCP サーバーを登録して、CLI からツールの一覧と実行をさせる小さなゲートウェイ）は、
`langchain-mcp-adapters` 0.3.2 が `mcp<2.0.0` に固定しているため MCP Python SDK 2 へ上がれません。上流は 2026-09-11 に保守を終え、
MCP の対応は LangChain 本体の `langchain.mcp`（`langchain[mcp]`、中身は fastmcp 4）へ移りました。

この lab では、移行するかどうかを決めるために、旧と新のクライアントを MCP 1 と MCP 2 のサーバーへ実際につなぎ、何が変わるかを確かめます。

## Purpose

1. 旧（kimcp 0.1.0 と同じ使い方）と新（kimcp を移行したときの使い方）で、3 つの接続方式（stdio・SSE・streamable HTTP）は動くか
2. 新しいクライアントは MCP 1 のサーバーにつながるか。旧いクライアントは MCP 2 のサーバーにつながるか
3. ツールの結果・エラー・画像・構造化出力の形は変わるか（kimcp の `run-tool` の出力に効く）
4. kimcp が持っている設定（タイムアウトなど）と、セッションを持ち続ける使い方は新しい側でも成り立つか
5. elicitation（ツールの実行中にサーバーが利用者へ入力を求める仕組み）はどうなるか
6. 新しくできるようになることは何か

## 条件

| | v1（旧） | v2（新） |
| --- | --- | --- |
| クライアント | `langchain-mcp-adapters` 0.3.2 + `mcp` 1.30.0 + `langchain-core` 1.6.5 | `langchain[mcp]` 1.4.2 + `fastmcp` 4.0.10 + `mcp` 2.2.0 + `langchain-core` 1.6.5 |
| クライアントの使い方 | kimcp と同じ。`MultiServerMCPClient(...).session(name)` に入ったまま `load_mcp_tools(session)` → `tool.ainvoke(args)` | kimcp の移行案。`fastmcp.Client(transport)` に入ったまま `as_langchain_tool(tool, client)` → `tool.ainvoke(args)`。`MCPAdapter` は別に試す |
| サーバー | `mcp.server.fastmcp.FastMCP`（`v1/server.py`） | `mcp.server.mcpserver.MCPServer`（`v2/server.py`） |

- 両方のサーバーに同じツールを置いた（`add`、`pid`、`image`、`structured`、`fail`、`open_object`、`slow`、`ask`）。
  v2 のサーバーには、新しいプロトコル（2026-07-28）流の elicitation を試す `ask_modern` も置いた
- クライアント 2 × サーバー 2 × 接続方式 3 の 12 通りに、新クライアントの `mode="legacy"`（旧来の initialize ハンドシェイクを強制する）4 通りを足して 16 通り
- 旧と新は別々の uv 環境で動かし、同じプロセスに mcp の 2 つのメジャー版が混ざらないようにした
- Python 3.13.12、macOS 26.6（Apple Silicon）。すべて 127.0.0.1 上

```sh
mise -C 2026/09/29/kimcp-mcp2-migration run            # 16 通りすべて
mise -C 2026/09/29/kimcp-mcp2-migration run -- client-v2__server-v2   # キーの一部で絞る
```

結果は `results/matrix.json`（絞ったときは `results/matrix.partial.json`）に書き出す。このリポジトリにあるのは 2026-09-29 に実行したもの。

## Answer

### 変わらないもの

- **3 つの接続方式はすべて、新しい側でも動きました。** SSE も動きます。ただし SSE はプロトコル上は非推奨で、新しいプロトコル（2026-07-28）には
  乗りません（SSE でつなぐと 2025-11-25 の旧来のハンドシェイクになる）
- **新しいクライアントは MCP 1 のサーバーにもそのままつながりました**（自動で 2025-11-25 に落ちる）。kimcp が第三者の MCP 1 のサーバーを
  使えなくなることはありません
- **ツールの結果の形は同じでした。** `ainvoke` の戻り値は、新旧とも LangChain の content block のリスト（テキスト、画像は base64 と mime_type）。
  `ToolCall` で呼ぶと構造化出力が `artifact={'structured_content': ...}` に入るところも同じです
- **ツールが失敗したとき（`isError=True`）は、新旧とも例外にならず、エラーの文面が結果として返ります。**
  kimcp の `run-tool` は、新旧どちらでも HTTP 200 でエラー文面を返すことになります
- 開いたオブジェクトの引数（`dict[str, Any]`）の schema は、新旧とも `additionalProperties: true` でした
- 1 つの接続に入ったままにすれば、呼び出しをまたいで同じサーバープロセス（stdio）・同じセッションが使われました（`pid` が 2 回とも同じ）

### 変わるもの（kimcp 側で手当てが要る）

- **stdio のサーバーは、クライアントの `async with` を抜けても止まりません。** fastmcp の `StdioTransport` は `keep_alive` の既定が True で、
  サーバーの子プロセスが残ります。`await client.transport.close()` を呼ぶと止まりました（全 stdio の組み合わせで確認）。
  kimcp の `disconnect` でこれを呼ばないと、切断したはずの stdio サーバーが残り続けます
- **接続設定の項目が一部なくなります。** fastmcp の transport には、SSE の `timeout`、streamable HTTP の `timeout`・`sse_read_timeout`・
  `terminate_on_close`、stdio の `encoding`、全方式共通の `session_kwargs` に当たる引数がありません。リクエストのタイムアウトは
  `Client(timeout=...)` に移り、認証は `Client(auth=...)`（bearer トークン文字列、`"oauth"`、`httpx2.Auth`）になります
- **新しいプロトコルの streamable HTTP では、タイムアウトの後に接続ごと使えなくなりました。** v2 クライアントと v2 サーバーを
  2026-07-28 でつなぎ、1 秒のタイムアウトで 2 秒のツールを呼ぶと、次の `add` は `RuntimeError: Client is not connected` になり、
  切断は `httpx2.ReadTimeout` で失敗しました（3 回とも同じ）。`mode="legacy"` にすると、タイムアウトの後も `add` が通り、切断もできました。
  MCP 1 のサーバーや stdio、SSE では起きません。上流の不具合か仕様かは確かめていません
- **elicitation の扱いが変わります。**
  - 旧：ハンドラーが無ければサーバーに「非対応」と返り、ハンドラーを渡せば答えられた（kimcp はハンドラーを持たない）
  - 新・旧来のプロトコル（2025-11-25）：`Client(elicitation_handler=...)` で同じように答えられた
  - 新・新しいプロトコル（2026-07-28）：サーバーが `ctx.elicit()`（サーバーから呼びかける旧来の方法）を使うと、クライアントにハンドラーがあっても
    `Cannot send 'elicitation/create': this transport context has no back-channel` で失敗した。サーバーが `InputRequiredResult`
    （入力の要求を結果として返し、クライアントが答えを付けて呼び直す新しい方法）を返す場合は、`elicitation_handler` で答えられた
  - `MCPAdapter` の既定は、elicitation を LangGraph の interrupt として扱う。LangGraph の外（kimcp の `run-tool` のような直接の `ainvoke`）で
    `InputRequiredResult` が返ると `KeyError: '__pregel_scratchpad'` になった。kimcp は `MCPAdapter` ではなく `fastmcp.Client` を直接持つほうが合う
- **`langchain.mcp` はベータです。** import すると `LangChainBetaWarning` が出て、API は変わりうると明記されています
- **依存が増えます。** 環境のパッケージ数は旧 52 → 新 91、`.venv` は 55 MB → 93 MB。langgraph 一式、fastmcp、httpx2、opentelemetry-api などが入り、
  kimcp が直接使う `httpx` と、MCP 2 が使う `httpx2` が並びます。参考に、`fastmcp-slim[client]` だけなら 51、`mcp` 2.2.0 だけなら 28 パッケージ
- 初回の `add` は、HTTP で旧 5〜7 ms → 新 38〜40 ms、stdio で旧 5.6 ms → 新 19〜20 ms（1 回ずつの値。2 回目以降の `pid` は新旧とも 1〜2 ms）

### 新旧のどちらでも起きる、クライアントと関係のない違い

- **MCP 2 のサーバーは、ツール内の例外の文面をクライアントへ返しません。** v1 のサーバーは `Error executing tool fail: boom from tool`、
  v2 のサーバーは `Error executing tool fail` だけ。v2 のサーバーの失敗は約 150 ms かかった（サーバーが traceback をログに出している）
- **旧いクライアント（今の kimcp）で MCP 2 の stdio サーバーを使うと、タイムアウトの後の切断が `ExceptionGroup`（中身は `anyio.BrokenResourceError`）で失敗しました**（3 回とも同じ）。
  タイムアウトの後の `add` は通ります。kimcp の `disconnect` は例外を警告のログにして進むので、利用者からは見えにくい
- v2 のサーバーの `ask_modern`（`InputRequiredResult` を返す）は、旧来のプロトコルでつながると `Handler returned an invalid result` になった。
  2 つのプロトコルの両方に対応するのはサーバー側の責任

### 新しくできるようになること

- MCP 2 の新しいプロトコル（2026-07-28）で、MCP 2 のサーバーと話せる（stdio と streamable HTTP で確認）。セッションを持たない HTTP、
  `server/discover`、サーバーの TTL に従うツール一覧のキャッシュ（`list_tools(cache_mode=...)`）が使える
- `fastmcp.Client` をそのまま持つので、`list_resources`・`list_prompts` などツール以外の MCP の機能も呼べる（新旧のどちらのサーバーでも応答した。
  ただし `langchain.mcp` 自身は resources と prompts を包んでいない）
- `Client(auth="oauth")` による OAuth、`Client(auth="<token>")` による bearer 認証が、接続設定を組み立てずに使える
- `fastmcp.mcp_config.MCPConfig`（Claude Desktop などと同じ `mcpServers` の形の設定）から、複数のサーバーへまとめてつなげる
- ツールのメタデータに、サーバーの名前と版（`metadata["mcp"]["server"]`）とツールの annotations が入る

### 確かめていないこと

- WebSocket（MCP 2 で削除。kimcp はもともと対応していない）
- 認証付きのサーバー、TLS の検証（MCP 2 は certifi ではなく OS の信頼ストアを使う）
- Windows、Python 3.12
- 長時間の接続、サーバーの再起動からの復帰、同時に多数の呼び出し
- 新しいプロトコルで HTTP のタイムアウトの後に接続が使えなくなる件が、fastmcp と MCP SDK のどちらに由来するか

## ファイル

- `v1/` `v2/` — それぞれの uv 環境、テスト用サーバー（`server.py`）、クライアント（`client.py`）
- `run_matrix.py` — 16 通りを回して `results/matrix.json` に書く（標準ライブラリだけ）
- `results/matrix.json` — 2026-09-29 の実行結果
