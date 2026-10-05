# A Codex-app-like Flutter client on the Claude Agent SDK, running on a Claude subscription

[codex app-server で作った Codex アプリの写し](../../01/flutter-codex-app-server/README.md)と同じ機能の Flutter（macOS）アプリを、
[Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview)（TypeScript）で作り、Claude のサブスク（Max）のログインで動くかを確かめます。

## Purpose

1. Agent SDK を Flutter から使えるか（SDK は Node / Python 専用）
2. Claude のサブスクのログインで動くか。規約上どう扱われるか
3. Codex 版の機能（スレッドの一覧・新規・再開・削除、ストリーミング、コマンド・ファイル編集・差分の表示、承認、モデル・推論の強さ・モード、
   実行中の追加入力、このアプリのスレッドだけを出す、セクション）がどこまで写せるか

## Answer

- **動きました。** Node の小さな中継プロセス（`sidecar/`、SDK の `query()` を持つ）を Flutter が子プロセスで起動し、1 行 1 JSON でやり取りします。
  Codex 版の UI（約 2,800 行）をほぼそのまま使い、作り直したのは通信（`lib/claude/`）と SDK のメッセージを画面の項目に写す部分（`lib/state/thread_view.dart`）です
- **Max のサブスクで動きました。** SDK は同梱の Claude Code を子プロセスで動かし、その Claude Code 自身のログイン（`claude auth login`、
  macOS のキーチェーン）を使います。アプリは資格情報に触れません。`accountInfo()` は `{email, subscriptionType: "Claude Max"}` を返します
- 題材（バグ入りの `fizzbuzz.py` を直して pytest のテストを足す）は、Bypass permissions のモードで最後まで通りました。
  既定のモード（Ask permissions）では、ファイルを書き換える Bash の前に承認を求めて止まります（承認カードの操作は「Findings」の未確認を参照）

### Codex 版との対応

| Codex 版（app-server） | この lab（Agent SDK） |
| --- | --- |
| `thread/start`・`turn/start` | `query({prompt: AsyncIterable, options: {sessionId}})`。新しいセッションの ID は自分で決められる |
| `thread/resume` の履歴 | `getSessionMessages()`（生の API メッセージだけ。ターンの区切り・所要時間・構造化されたツールの結果は無い） |
| `thread/list`・`thread/read` | `listSessions()`・`getSessionInfo()` |
| `thread/archive` | 無い。`deleteSession()`（消える） |
| セクション（`threadSection/*`） | 無い。`tagSession()` のタグで代用し、空のセクションは手元に覚える |
| `item/*` の通知 | `stream_event`（部分）・`assistant`（ブロックごと）・`user`（`tool_result`）・`result` |
| ターン全体の差分（`turn/diff/updated`） | 無い。`Edit`・`Write` の `tool_use_result.structuredPatch` から組み立てる |
| 承認（`item/*/requestApproval`） | `canUseTool`。`suggestions`（「このセッションは編集を許可」など）を `updatedPermissions` で返すと以後は聞かれない |
| `turn/steer` | 実行中に `priority: "now"` のユーザーメッセージを流す |
| `turn/interrupt` | `query.interrupt()` |
| モデル一覧（`model/list`） | `query.supportedModels()`（推論の強さの選択肢付き） |
| 利用枠（`account/rateLimits/*`） | `rate_limit_event`（5 時間・週の枠の状態） |
| アクセスのモード（3 つ） | パーミッションモード（default・acceptEdits・plan・auto・bypassPermissions）。途中で `setPermissionMode()` |
| Chrome（Codex アプリの設定の `cua_repl`） | `extraArgs: {chrome: null}`（Claude in Chrome） |
| computer use | 無い（対話型のセッションだけ） |

## Architecture

```text
sidecar/src/main.ts   （Node 22 の型の取り除きでそのまま実行。tsc は型検査だけ）
  initialize            → 何も送らない query() を立てて supportedModels()・accountInfo() を取り、閉じる
  session/start         → query() を streaming input で立て、最初のメッセージを流す
  session/send          → 動いている query() が無ければ resume で立て、メッセージを流す（実行中なら priority "now"）
  session/interrupt・setModel・setEffort（applyFlagSettings の effortLevel）・setPermissionMode・contextUsage
  session/infos・list・messages・rename・tag・delete（SDK のセッションの関数）
  → app: sdk/message（SDK のメッセージをそのまま）、permission/request（canUseTool。app の返事を待つ）

app/lib/
  claude/bridge_client.dart   中継プロセスとの JSON-RPC（Codex 版の app-server の client と同じ作り）
  state/thread_view.dart      SDK のメッセージ → ターンと項目（userMessage・agentMessage・reasoning・commandExecution・fileChange・…）
  state/thread_store.dart     このアプリが作ったセッションの ID と、セクションの名前
  state/app_controller.dart   接続・モデル・セッションの一覧・送信・中断・承認・セクション
  ui/                         Codex 版から写した画面（承認カードは canUseTool 向けに作り直した）
```

## Findings

- **SDK はユーザーのメッセージを送り返さない**ので、送ったメッセージはアプリが自分でターンに足す。SDK のメッセージは、まだ終わっていない一番古いターンへ入れ、
  `result` でそのターンを終える
- **1 つの応答は、ブロックごとに別の `assistant` メッセージで届く**（同じ API のメッセージ ID）。ストリーム（`content_block_start` の index）と
  完成したメッセージ（content の位置）とで番号が合わないので、「同じメッセージ ID の、まだ終わっていない同じ種類の項目」で突き合わせる
- **steer（実行中の追加入力）**: `priority: "now"` で流すと、SDK は実行中のツールが終わるのを待って、そのターンを打ち切る
  （`result` の `terminal_reason: "aborted_tools"`、本文は空）。続けて追加のメッセージで次のターンが走り、それまでの文脈を引き継ぐ。
  `sleep 12` の途中で「notes.txt ではなく steer.txt に書いて」と送ると steer.txt に書いた
- **ログインは Claude Code のもの。** `claude auth login`（claude.ai のサブスク）を一度しておく。未ログインだと `accountInfo()` が
  `tokenSource: "none"` を返し、メッセージは `Not logged in · Please run /login` で終わる
- **Claude Code のホストの中から起動すると、ホストの認証を借りてしまう。** macOS の `open` は呼び出した側の環境変数をアプリに渡すので、
  Claude デスクトップアプリの中のターミナルやエージェントから `open` すると、`CLAUDECODE`・`CLAUDE_CODE_*`（ホストのセッション・認証）・
  ホストを指す `ANTHROPIC_BASE_URL` がアプリ → 中継 → Claude Code へ漏れ、セッションの記録の `entrypoint` が `claude-desktop` になった。
  起動スクリプトは空の環境から `open` し、中継プロセスもこれらを取り除いて SDK に渡す（直した後は `entrypoint: "sdk-ts"`）
- **Chrome は使える（`--chrome`）。** SDK から起動した Claude Code には、標準ではブラウザも computer use も無い（ツールにも MCP サーバーにも無い）。
  `extraArgs: {chrome: null}`（CLI の `--chrome`）を渡すと `claude-in-chrome` の MCP がつながり、`navigate`・`read_page` などが揃う。
  同じアカウントに複数の Chrome（拡張）がつながっていると、最初に `AskUserQuestion` でどれを使うか聞いてくる。アプリの質問カードで
  「すべての Chrome に確認画面を出す」を選び、Chrome 側で選ぶと、example.com を開いてタイトル（Example Domain）を読んだ。アプリでは入力欄の「Chrome」で切り替える
  （Claude Code の起動時に効くので、切り替えると止まっているセッションのプロセスを閉じ、次の送信で立て直す）
- **computer use は使えない。** SDK は Claude Code を端末の画面（TUI）無しで、標準入出力の JSON で動かす
  （実際の引数: `claude --output-format stream-json --verbose --input-format stream-json [--chrome]`。`-p` は付かない）。会話としては複数ターン・steer・承認ができるが、
  [公式](https://code.claude.com/docs/en/computer-use)の computer use は「interactive session」（ターミナルの対話画面）が前提で、アプリごとの許可を端末の確認画面で聞く。
  SDK のセッションには組み込みの `computer-use` サーバーが出てこず、`toggleMcpServer('computer-use', true)` は `Server not found: computer-use`
  （同ページが名指しで除外しているのは `-p` だけで、SDK のセッションで出ないのは実測）。Codex 版は app-server 経由で computer use まで使えたので、ここは差になる
- **組み込みの computer use を SDK から呼ぶ抜け道も無い**（2026-10-05、Claude Code 2.1.289）。
  - 組み込みの `computer-use` は、Claude Code 自身を内部の引数 `--computer-use-mcp` で起動した stdio の MCP サーバー。対話モードの CLI だけが自分で登録する
  - 設定の `enabledMcpServers: ['computer-use']` を渡しても、サーバー自体が登録されない。`mcpServers` に `computer-use` の名前で登録すると予約名として消される
  - 別の名前（`mac`）で `{command: <同梱の claude>, args: ['--computer-use-mcp']}` を登録すると、つながってツール一式（`request_access`・`screenshot`・`left_click`・
    `type`・`computer_batch` など 26 個）が出る。ただし呼ぶと全部「This computer-use server instance is not wired to a session. Per-session app permissions are not
    available on this code path.」。単体のサーバーはツールの一覧を返すだけで、呼び出しの本体は CLI の本体が `computer-use` の名前のときだけ自分の中で処理する作り。
    外から届く経路は無い（本体を改変すれば別だが、それはしない）
  - 残る道: 外部の macOS 操作の MCP サーバー（Peekaboo・mac-use-mcp など）を `mcpServers` に足す、SDK の `createSdkMcpServer` で自前の画面操作ツールを書く
- **Peekaboo（外部の MCP サーバー）なら Mac を操作できた**（2026-10-05、Peekaboo 4.8.0、Homebrew の `openclaw/tap/peekaboo`）。入力欄の「Mac」で
  `mcpServers: {peekaboo: {command: 'peekaboo', args: ['mcp', '--allow-foreground']}}` を足す。計算機で AC → 1・2・×・1・2・= を押して「144」を読んだ
  - `--allow-foreground` が無いと Peekaboo は裏での操作しかせず、起動していないアプリを開くのを拒む（「cold launch requires explicit foreground consent」）
  - macOS の権限（画面収録・アクセシビリティ・イベントの合成）は、Peekaboo を起動したアプリ（この lab の Flutter アプリ）に付く。初回にダイアログが出て、
    画面収録は許可の後にアプリの再起動が要った。Debug ビルドを作り直すと署名が変わり、許可が外れることがある
  - 操作は遅い。Peekaboo は操作のたびに画面を取り直す（`see`）ことを求め、古い snapshot での操作を拒む。クリックは毎回「confirmed outcome が無い」と返るが反映はされていた。
    12×12 の入力に約 20 回のツール呼び出し。既定のモードでは 1 回ごとに承認カードが出る
  - Claude Code の computer use にあるアプリごとの許可・他のアプリを隠す・Esc で止める、は無い。歯止めはこのアプリの承認カード（canUseTool）と Peekaboo の前面操作の制限
- Flutter のウィンドウが他のウィンドウの後ろに隠れている間は描き直されず、裏で撮った画面は古いままになる（クリックすると最新になる）。アプリの不具合ではない
- 過去のセッションの履歴では、既存のファイルの上書き（Write）も「Created」に見える（履歴には `tool_use_result` が無く、新規か上書きかが分からない）
- 最初のメッセージを送る前に、モデル一覧とアカウントが取れる（何も送らない `query()` で約 1〜4 秒）
- `rate_limit_event` は 5 時間枠の状態（`allowed` など）と、超過分（overage）が使えるかを返す
- 読むだけのコマンド（`ls` など）は既定のモードでも聞かれない。ファイルの書き込みでは `canUseTool` が呼ばれ、
  提案（`{type: "setMode", mode: "acceptEdits", destination: "session"}`）を返すとそのセッションは以後編集で聞かれない

## 規約（2026-10-05 時点）

- 自分の Mac で、自分のサブスクで、Claude Code 自身のログインを使う個人用なら、[Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) の
  「Advertised usage limits for Pro and Max plans assume ordinary, individual usage of Claude Code and the Agent SDK」の範囲と読める
- 同ページは、開発者が自分のアプリに claude.ai のログインを組み込むこと、利用者の代わりにサブスクの資格情報で中継すること、
  資格情報やセッショントークンを集める・保存する・中継することを禁じている。上の「ホストの認証を借りる」状態はこれに当たりうるので避けた
- 他人に配る場合は文書どうしが食い違う。[SDK の概要](https://code.claude.com/docs/en/agent-sdk/overview)は「Unless previously approved, Anthropic does not allow
  third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK」、
  [サポート記事](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)（2026-06-15 の更新）は
  「Claude Agent SDK, `claude -p`, and third-party app usage still draw from your subscription's usage limits」で、Agent SDK でサブスクに認証する
  他社のアプリを前提に書いている。配る前に最新の文面を確かめる

## How to run

前提: Claude Code にサブスクでログイン済み（`claude auth login`）、mise。

```bash
mise run            # sidecar の型検査と flutter analyze
mise run run        # macOS 版をビルドして開く
CLAUDE_FLUTTER_CWD=path/to/project CLAUDE_FLUTTER_MODE=bypassPermissions \
  CLAUDE_FLUTTER_PROMPT="..." mise run run   # プロジェクト・モード・最初のメッセージを指定して開く
```

## Environment

- macOS 27.0.1、MacBook Pro M1 Max
- Flutter 3.47.2、Dart 3.13、Node 22.22
- `@anthropic-ai/claude-agent-sdk` 0.3.289（同梱の Claude Code 2.1.289）、TypeScript 7.0.2
- Claude Max
