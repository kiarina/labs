import 'package:flutter/foundation.dart';

import '../agents/agent_thread.dart';
import '../agents/backends.dart';
import '../body/body.dart' show claudeLoggedIn;
import '../rpc/rpc_client.dart';
import '../state/thread_view.dart' show Json;
import 'brain_config.dart';

/// The process the orchestrator runs in: one agent ([BrainConfig.kind]),
/// started for the brain alone. A body on the same app runs its workers in
/// processes of its own, so changing either one's settings restarts only
/// its own agents (the logins in `~/.codex` and Claude Code are shared).
class BrainAgent extends ChangeNotifier {
  BrainAgent({
    required this.stateDir,
    required this.onTool,
    this.onUserPrompt,
    this.log,
  });

  final String stateDir;

  /// The orchestrator's tool calls (the hub's tools).
  final ToolHandler onTool;

  /// A Claude orchestrator asks the user (AskUserQuestion).
  final void Function()? onUserPrompt;

  /// Keeps the protocol traffic for the console's log.
  final void Function(RpcClient client)? log;

  BrainConfig config = BrainConfig();
  CodexBackend? _codex;
  ClaudeBackend? _claude;

  /// Started (or failed: [error]).
  bool ready = false;

  /// Why the orchestrator cannot run (not logged in, server unreachable,
  /// incomplete settings).
  String? error;

  List<Json> get models => _codex?.models ?? _claude?.models ?? const [];

  String? get defaultModel => _codex?.defaultModel ?? _claude?.defaultModel;

  /// The model a new conversation uses: the one set, if the agent has it.
  String? get model {
    final m = config.model;
    if (config.kind == WorkerKind.custom) return m;
    return m != null && models.any((x) => x['id'] == m) ? m : defaultModel;
  }

  /// Starts the agent; [cwd] is where the orchestrator works.
  Future<void> start(BrainConfig c, {required String cwd}) async {
    config = c;
    ready = false;
    error = c.problem;
    notifyListeners();
    if (error == null) {
      try {
        switch (c.kind) {
          case WorkerKind.codex:
            final b = CodexBackend(
              await codexAppServer(name: 'brain-codex'),
              onTool: onTool,
            );
            log?.call(b.client);
            await b.start();
            _codex = b;
            if (b.account == null) {
              error = 'Codex is not logged in (log in on the start screen, or `codex login`)';
            }
          case WorkerKind.claude:
            final b = ClaudeBackend(claudeBridge(), onTool: onTool)
              ..onUserPrompt = ((_, _) => onUserPrompt?.call());
            log?.call(b.client);
            await b.start(cwd);
            _claude = b;
            if (!claudeLoggedIn(b.account)) {
              error = 'Claude is not logged in (`claude auth login`)';
            }
          case WorkerKind.custom:
            final t = c.customType().$1!;
            final b = CodexBackend(
              await customAppServer(t, '$stateDir/brain'),
              onTool: onTool,
              workerType: 'custom',
            );
            log?.call(b.client);
            await b.start();
            _codex = b;
        }
      } catch (e) {
        error = '$e';
      }
    }
    ready = true;
    notifyListeners();
  }

  /// New settings: stops the agent and starts it again.
  Future<void> restart(BrainConfig c, {required String cwd}) async {
    close();
    await start(c, cwd: cwd);
  }

  /// A new orchestrator conversation.
  AgentThread create({required String cwd, required AgentRole role}) {
    if (error != null) throw StateError(error!);
    final model = this.model;
    final effort = config.effort;
    if (_codex case final b?) {
      return b.create(
        label: 'orchestrator',
        cwd: cwd,
        role: role,
        model: model,
        effort: effort,
      );
    }
    if (_claude case final b?) {
      return b.create(
        label: 'orchestrator',
        cwd: cwd,
        role: role,
        model: model,
        effort: effort,
      );
    }
    throw StateError('the orchestrator\'s agent is not running');
  }

  /// An answer to a Claude orchestrator's question.
  void answer(Object requestId, Object? result) =>
      _claude?.client.respond(requestId, result);

  /// What consoles show: the agent, its models, why it cannot run.
  Json get info => {
    ...config.toJson(),
    'label': config.label,
    'ready': ready,
    'error': error,
    'models': models,
    'model': model,
  };

  void close() {
    _codex?.client.dispose();
    _claude?.client.dispose();
    _codex = null;
    _claude = null;
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
