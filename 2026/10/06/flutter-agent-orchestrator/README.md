# An orchestrator agent that runs Codex and Claude threads as tools, in one Flutter app

1 つの Flutter（macOS）アプリに `codex app-server` と Claude Agent SDK の両方を組み込み、上位のエージェント（司令塔）が Codex と Claude の
スレッドをツールとして立てる・待つ・読む・止めるようにします。ユーザーは司令塔とだけ話します。

前提となる lab:
- [codex app-server で作った Codex アプリの写し](../../01/flutter-codex-app-server/README.md)
- [同じ機能を Claude Agent SDK とサブスクで作ったもの](../../05/flutter-claude-agent-sdk/README.md)

## Purpose

1. 司令塔（Codex か Claude、切り替えられる）に、両方のワーカーをツールとして渡せるか
2. 並列に走らせる・結果を待つ・別のスレッドに渡す・止める、を司令塔に任せられるか
3. 同時に走らせる数の上限と、動いているスレッドの一覧・停止を、画面と設定で扱えるか

## Answer

- **作れました。** 司令塔（Codex）に「fizzbuzz.py の修正とテストを Codex に、slugify.py の改善とテストを Claude に、並列で」と頼むと、
  担当ファイルを分けて 2 つのワーカーを立て、`wait_threads` で両方を待ち、結果を読んで全体のテスト（31 件成功）まで確かめて報告した
- ツールの実体は Flutter（Dart）に 1 つだけ書き、Codex の司令塔にも Claude の司令塔にも同じ定義（JSON Schema）を渡せる
  - Codex: `thread/start` の `dynamicTools`（実験的。`initialize` で `experimentalApi: true` が要る）。呼ばれると `item/tool/call` がアプリに届く
  - Claude: SDK の `createSdkMcpServer` + `tool()`。中継プロセスが JSON Schema を `z.fromJSONSchema()`（zod 4）で zod に変え、呼び出しを `tool/call` でアプリに送る

## Architecture

```text
Flutter app (Hub)
  ├─ CodexBackend ── codex app-server（1 プロセス）── 司令塔 / ワーカーのスレッド × N
  ├─ ClaudeBackend ─ sidecar（Node, Agent SDK）──── 司令塔 / ワーカーのセッション × N（セッションごとに Claude Code のプロセス）
  └─ Hub: ワーカーの台帳・同時実行の上限と順番待ち・ツールの実行・終わったことの通知
```

- `lib/rpc/rpc_client.dart`: 両方に共通の、改行区切りの JSON-RPC
- `lib/agents/agent_thread.dart`: 司令塔とワーカーの共通の形（状態: queued・running・idle・failed・interrupted・cancelled）
- `lib/agents/backends.dart`: Codex のスレッドと Claude のセッションの立て方・送り方・止め方
- `lib/orchestrator/tools.dart`: 司令塔のツール（JSON Schema）と司令塔への指示
- `lib/orchestrator/hub.dart`: ツールの実行、同時実行の上限、司令塔への通知、設定
- `lib/state/thread_view.dart`: 会話の表示のモデル（Codex の通知と SDK のメッセージの両方を読む）

### 司令塔のツール

| ツール | すること |
| --- | --- |
| `start_thread(provider, prompt, title?, cwd?, model?)` | ワーカーを立てて最初の仕事を渡す。待たずに ID を返す。上限に達していれば順番待ち |
| `send_message(thread_id, message)` | 実行中なら steer、止まっていれば次のターン（上限なら順番待ち） |
| `wait_threads(thread_ids?, mode any/all, timeout_seconds)` | 終わるまで待ち、終わったものは最後の回答も返す |
| `read_thread(thread_id, detail summary/full)` | 状態・最後の回答・変更したファイル・実行したコマンド・エラー（full は会話の文字起こし） |
| `interrupt_thread(thread_id)` | 実行中なら中断、順番待ちなら取り消し |
| `list_threads()` | 全ワーカーと上限 |

- ワーカーは承認なしで走る（Codex: `approvalPolicy: never` + `danger-full-access`、Claude: `bypassPermissions`）
- 司令塔は自分では編集しない（Codex: 読み取り専用のサンドボックス、Claude: `Edit`・`Write` などを外す）。同じリポジトリを並列で触らせるかは司令塔が決める（指示に書いた）
- ワーカーが終わると、司令塔に `[worker update]` を送る（1.5 秒まとめる。司令塔が `wait_threads` で待っているワーカーは送らない）。
  司令塔が動いていれば Codex は steer、Claude は `priority: "next"`。止まっていれば設定「Wake the orchestrator when a worker finishes」で新しいターンを始める

### 画面

- 左: 司令塔の切り替え（Codex / Claude。切り替えると新しい会話）、新しい会話、プロジェクト、設定（同時実行の上限・起こすか・ワーカーの既定のモデル）、両方の利用枠
- 中央: 司令塔との会話（入力はここだけ）。ワーカーを開くとその会話を表示し、止めるボタンを出す
- 右: ワーカーの一覧（実行中・順番待ちを上に、経過時間、止めるボタン）

## Findings

- Codex の司令塔は動的ツールを、Codex の code mode の中から呼んだ（`function_call` は `wait` などの JS のセルの操作として記録され、ツールの結果はその出力になる）
- Claude の司令塔は、自前の MCP ツールを最初に `ToolSearch` で探してから呼ぶ。`tool()` の `alwaysLoad: true` で最初から読み込ませる
- 同時実行の上限は設定（既定 4）。上限を超えた `start_thread` は順番待ちになり、ワーカーが終わるたびに先頭から始める

## How to run

前提: `codex login` と `claude auth login`（サブスク）を済ませておく、mise。

```bash
mise run            # sidecar の型検査と flutter analyze
mise run run        # macOS 版をビルドして開く
ORCH_CWD=path/to/project ORCH_PROVIDER=codex ORCH_PROMPT="..." mise run run   # プロジェクト・司令塔・最初の依頼を指定して開く
```

設定は `~/Library/Application Support/com.kiarina.labs.agentOrchestrator/settings.json`（`ORCH_STATE_DIR` で変えられる）。

## Environment

- macOS 27.0.1、MacBook Pro M1 Max
- Flutter 3.47.2、Dart 3.13、Node 22.22
- codex-cli 0.159.3、`@anthropic-ai/claude-agent-sdk` 0.3.289（同梱の Claude Code 2.1.289）、zod 4.6.5
- ChatGPT（Codex）と Claude Max のサブスク
