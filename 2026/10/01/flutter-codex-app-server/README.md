# A Codex desktop app clone in Flutter on top of codex app-server

`codex app-server`（Codex CLI に入っている、Codex の IDE 拡張やデスクトップアプリが使う JSON-RPC のサーバー）を Flutter から
子プロセスとして起動し、Codex のデスクトップアプリに近いクライアントを作れるかを確かめます。

## Purpose

1. Flutter（macOS）から `codex app-server` を起動し、stdio の JSON-RPC で会話できるか
2. Codex アプリの基本の体験（スレッドの一覧・新規・再開、ストリーミング、コマンドやファイル編集の表示、承認、中断、モデルの選択）を
   どこまで再現できるか、どれくらいの手間か
3. プロトコルで気をつける点

## Answer

- **作れました。** 約 2,800 行の Dart（dart format 後）（依存は `markdown_widget` と `file_selector` だけ）で、次がすべて実際の Codex（`codex-cli 0.159.3`、
  ChatGPT アカウント、`gpt-6.1-sol`）で動きました
  - スレッドの一覧（プロジェクト = cwd ごとにまとめる）、新規作成（最初の送信で `thread/start`）、過去のスレッドの再開（`thread/resume` で履歴が戻る）、アーカイブ
  - 回答のストリーミング（`item/agentMessage/delta`）。途中の進捗（`phase: "commentary"`）と最終回答（`"final_answer"`）を描き分ける
  - コマンド実行・ファイル作成と編集（差分）・MCP の tool 呼び出し・計画・推論の要約を、折りたためる行で表示
  - ターン全体の差分（`turn/diff/updated`）、所要時間、コンテキストの使用量、週の利用枠
  - 承認: Read only モードで書き込みを頼むと `item/commandExecution/requestApproval` が届き、カードの Approve で実行されて NOTES.md が書かれた
  - モデル・推論の強さ・アクセスのモード（Read only / Agent / Full access）の切り替え。実行中の入力は `turn/steer` に回す
- 検証の題材: 境界のバグ（`range(1, n)`、15 の倍数の判定順）を入れた `fizzbuzz.py` を渡し、「直して pytest のテストを足して実行して」と頼むと、
  調査 → テスト作成 → 失敗（exit 1）→ 修正 → 成功 → 最終回答、の 39 秒のターンがそのまま描けた
- **app-server がほぼすべてを持っているので、クライアントは「通知を item ごとに積んで描く」だけで済みます。** 認証・モデル一覧・履歴の保存・
  サンドボックス・MCP サーバーの起動はサーバー側で、ユーザーの `~/.codex/config.toml` もそのまま効きます

### 作っていないもの（Codex アプリにはある）

worktree・クラウドのタスク、差分のレビュー画面（行へのコメント）、内蔵ターミナル、画像の添付、`@` でのファイル指定と slash command、
skills / plugins の管理、レビューモード（`review/start`）、サブエージェントのスレッド、ログイン画面（`account/login/start`）、設定画面。
プロトコルにはどれも口があります（`ClientRequest` に 100 余りのメソッド）。

## Architecture

```text
app/lib/
  codex/app_server_client.dart  Process.start('codex', ['app-server']) と、改行区切りの JSON-RPC（request / notify / respond）
  state/app_controller.dart     接続・アカウント・モデル・スレッド一覧・送信・中断・承認の返答
  state/thread_store.dart       このアプリが作ったスレッドの ID と最後に使った時刻（CODEX_HOME ごと）
  state/thread_view.dart        開いているスレッドの turn → item。通知（item/started・delta・completed など）を反映
  ui/                           サイドバー、トランスクリプト、item ごとの表示、承認カード、入力欄
```

起動の流れ: `initialize`（clientInfo）→ `initialized` → `account/read`・`model/list`・`thread/list`・`account/rateLimits/read`。
送信: スレッドが無ければ `thread/start {cwd, model, approvalPolicy, sandbox}` → `turn/start {threadId, input, model, effort, approvalPolicy, sandboxPolicy}`。

## Findings

- メッセージは 1 行 1 JSON の JSON-RPC 2.0 で、**`"jsonrpc": "2.0"` は付かない**（送るときも要らない）。サーバーからの request（承認）は
  `id` と `method` の両方を持つので、`id` だけの response と区別する
- 1 つの item は `item/started` → delta → `item/completed` で届き、`completed` の中身が正。delta だけを信じると、
  最終形（`aggregatedOutput`・`exitCode`・`changes`）を取りこぼす
- ファイルの変更は `kind` が `add`・`delete` のとき `diff` にファイルの中身そのものが入り、`update` のときだけ unified diff。
  差分として描くには add / delete の行に `+` / `-` を付ける
- `thread/list` は `sourceKinds` を省くと「対話のソース」だけを返す。CLI・IDE・app-server（このアプリ）のスレッドを並べるには
  `['cli', 'vscode', 'appServer', 'exec']` を明示した
- **このアプリで作ったスレッドだけを並べられる**（2026-10-04）。
  - スレッドには `initialize` の `clientInfo.name` が `originator` として残る（このアプリは `codex_flutter`、Codex アプリは `Codex Desktop`、
    `codex exec` は `codex_exec`）。ただし `thread/list` の `originators` での絞り込みはローカルの app-server では
    `originator filtering is not supported by the local app-server` で弾かれ、全件をたどって手元で絞るしかない（876 件で 1.5 秒。全体の件数に比例する）
  - そこで、このアプリが作ったスレッドの ID を手元のファイル（`~/Library/Application Support/<bundle id>/threads.json`、CODEX_HOME ごと）に覚え、
    最近使った 50 件を `thread/read` で読む（「Show more」で 50 件ずつ増やす）。費用は表示する件数だけで決まる。ファイルが無い初回だけ、
    `originator` で全件をたどって取り込む
  - 外で消されたスレッドは `thread/read` が `thread not loaded: <id>` を返すので、ファイルから外す。アーカイブは Thread に印が無く、
    `path` が `archived_sessions/` に移ることでしか分からない（`path` は UNSTABLE）
- **スレッドのセクションはサーバー側（`threadSection/*`、`thread/section/move`）で管理する**（2026-10-04）。セクションは CODEX_HOME にあり、
  Codex アプリと共有（Codex アプリの「Pinned」もセクション）。作成・名前の変更・削除・スレッドの出し入れを確かめた。
  セクションを消すと中のスレッドはセクションなしに戻る。セクションの操作には通知が来ない（他のクライアントの変更は読み直すまで分からない）
- `thread/resume` は turn と item を返すが、**ターン全体の差分（`turn/diff/updated`）は再開しても戻らない**（保存されない）
- `thread/start` の直後に、ユーザーの設定の MCP サーバー（この環境では 4 つ）の `mcpServer/startupStatus/updated` が届く。
  サンドボックスや承認の方針も含め、ユーザーの `~/.codex/config.toml` が効く
- `thread/start` はサンドボックスを文字列（`SandboxMode`: `workspace-write` など）、`turn/start` はオブジェクト（`SandboxPolicy`:
  `{type: "workspaceWrite", ...}`）で受ける。名前も形も違う
- **app-server 経由でも Chrome を操作できた**（2026-10-02）。Codex アプリが `~/.codex/config.toml` に書いた `cua_repl` の MCP（実体は Codex アプリに同梱）と
  Chrome プラグインがそのまま効き、`cua.createBrowserTab("chrome", url)` で開いて DOM を読んだ。Codex アプリが入っていない環境では使えない。
  Codex アプリの内蔵ブラウザ（`iab`）は試していない
- **computer use（Mac のアプリの操作）も app-server 経由でできた**（2026-10-02）。同じ `cua_repl` の MCP で計算機を開いてキーを押し、結果を読んだ。
  アプリを使ってよいかは `mcpServer/elicitation/request`（`mode: "form"`、`message: "Allow Computer Use to use \"Calculator\"?"`）で聞いてくる。
  - 返事は `{"action": "accept", "content": {}, "_meta": null}`。承認の形（`{"decision": ...}`）で返すと断った扱いになる
  - `_meta.persist`（`["session", "always"]`）のどれかを `_meta: {"persist": "session"}` で返すと、以後は聞かれない。返さないと **キー 1 つごとに** 聞かれる
    （「56×78」を 1 キーずつ押させると、承認が 1 回で済んだ）
  - **`approvalPolicy: "never"`（アプリの Full access）にすると、この問い合わせも来ない。** コマンド・ファイル変更・アプリの操作のどれも聞かれずに
    最後まで進んだ（計算機。`on-request` では同じ依頼で問い合わせが来る）
  - 承認を待っている間に `turn/interrupt` を送っても止まらず、承認に Decline で返すまで動き続けた
- macOS の App Sandbox の中からは子プロセスを起動できないので、entitlements で sandbox を外した。GUI から起動したアプリは
  シェルの `PATH` を継がないので、`/opt/homebrew/bin` などを探し、無ければ `zsh -lc` で起動する（`CODEX_BIN` で上書きできる）
- 検証の自動化: computer-use の背景操作（アクセシビリティ経由の入力）は Flutter の `TextField` に届かなかった。クリックは届く。
  そのため、最初のメッセージは環境変数 `CODEX_FLUTTER_PROMPT` で渡せるようにした
- **ログインは Codex 本体のもの。** `codex login`（ChatGPT）でアクセストークンとリフレッシュトークンが `~/.codex/auth.json` に入り、app-server が期限の前に
  自分で作り直して書き戻す（2026-10-07 に見たときアクセストークンの残りは約 9 日）。アプリは資格情報に触れない。ログインを求められるのは、最初の 1 回、
  リフレッシュトークンが使えなくなったとき（ログアウト・パスワードの変更・長く使わない・取り消し）、別のマシンや別の `CODEX_HOME` で使うとき
  - アプリから状態を読める: `account/read`（アカウント・プラン）、`account/rateLimits/read`（利用枠）
  - 未ログインなら、アプリからログインを始められる: `account/login/start` がブラウザで開く URL を返し、終わると `account/login/completed` が届く
    （`account/logout` もある）。Claude Agent SDK にはこの口が無い
  - アプリがトークンを持って渡す方式もあり、そのときは期限の前に app-server からアプリへ `account/chatgptAuthTokens/refresh` が来る（この lab では使っていない）
- 未検証: `turn/steer`、ファイル変更の承認（`item/fileChange/requestApproval`）、`item/tool/requestUserInput`
- 承認待ちでない時の中断（`turn/interrupt`）は、後の [司令塔の lab](../../06/flutter-agent-orchestrator/README.md) で確かめた（ターンは interrupted になるが、
  実行中のコマンドのプロセスは残る）

### 追記: `AGENTS.md` の読み込み（2026-10-09、codex-cli 0.159.3）

- 作業フォルダの `AGENTS.md` は自動で読まれ、`# AGENTS.md instructions for <cwd>` の見出しと `<INSTRUCTIONS>` に包まれて会話の先頭に入る
- `-c project_doc_max_bytes=0` で読まなくなる。`project_doc_fallback_filenames` で足した名前は、`AGENTS.md` が無いときだけ読まれる
- 基本の指示は `thread/start` の `baseInstructions` か、設定の `model_instructions_file` で差し替えられる（差し替えた結果は未確認）。`developerInstructions` は足すだけ
- 確かめ方は `../../09/flutter-agent-orchestrator-multi-brain/README.md` の「ワーカーに自動で入るプロンプト」

## How to run

前提: Codex CLI（`codex login` 済み）、mise。プロトコルは Codex の版で変わるので、`mise run schema` で手元の版のスキーマを `schema/` に出して比べてください。

```bash
mise run            # flutter analyze
mise run run        # macOS 版をビルドして開く
CODEX_FLUTTER_CWD=path/to/project CODEX_FLUTTER_ACCESS=read-only \
  CODEX_FLUTTER_PROMPT="..." mise run run   # プロジェクト・モード・最初のメッセージを指定して開く
mise run schema     # codex app-server generate-ts / generate-json-schema
# CODEX_FLUTTER_STATE_DIR で、覚えたスレッドの保存先を変えられる
```

## Environment

- macOS 27.0.1、MacBook Pro M1 Max
- Flutter 3.47.2、Dart 3.13
- codex-cli 0.159.3（Homebrew cask）
- markdown_widget 2.3.2+8、file_selector 1.1.0
