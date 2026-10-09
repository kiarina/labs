import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/thread_view.dart';

enum Provider {
  codex('Codex'),
  claude('Claude'),

  /// Codex with kiapi (a local model) as its model provider.
  kiapi('kiapi');

  const Provider(this.label);

  final String label;

  static Provider parse(String s) =>
      Provider.values.firstWhere((p) => p.name == s.toLowerCase());
}

/// Where a worker is in its life.
enum AgentState {
  /// Waiting for a free slot (the concurrency limit).
  queued,
  running,

  /// Finished its last turn; can take another message.
  idle,
  failed,
  interrupted,

  /// Removed from the queue before it started.
  cancelled,
}

/// One agent conversation (a Codex thread or a Claude session), used for both
/// the orchestrator and its workers. The backend fills [view] with the
/// transcript and calls [onTurnFinished] when a turn ends.
abstract class AgentThread extends ChangeNotifier {
  AgentThread({
    required this.label,
    required this.provider,
    required this.cwd,
    this.title,
    this.model,
    this.effort,
  }) : view = ThreadView(threadId: '', cwd: cwd, title: title);

  /// Short id shown to the user and the orchestrator ("w3", "orchestrator").
  final String label;

  /// Name of the app (body) the agent runs on.
  String body = '';
  final Provider provider;
  final String cwd;
  String? title;
  String? model;
  String? effort;
  final ThreadView view;
  final createdAt = DateTime.now();

  AgentState state = AgentState.queued;
  DateTime? turnStartedAt;
  DateTime? finishedAt;

  /// Text to send once a slot frees up (queued workers).
  String? pendingText;

  /// The backend's id: Codex thread id or Agent SDK session id.
  String? get backendId => view.threadId.isEmpty ? null : view.threadId;

  final _finished = StreamController<AgentThread>.broadcast();

  /// Fires when the agent has no turn left to run (steers that end a turn
  /// early and continue in the next one do not count).
  Stream<AgentThread> get finished => _finished.stream;

  /// Starts the conversation with its first message.
  Future<void> start(String text);

  /// Sends a message: a new turn when idle, a steer while running.
  Future<void> send(String text, {bool afterCurrentTurn = false});

  Future<void> interrupt();

  /// Releases backend resources (the Claude Code process of a session).
  Future<void> close();

  bool get isRunning => state == AgentState.running;

  void markRunning() {
    state = AgentState.running;
    turnStartedAt = DateTime.now();
    notifyListeners();
  }

  /// Called by the backend when a turn ends.
  void onTurnFinished() {
    if (view.isRunning) return;
    final last = view.turns.lastOrNull;
    state = switch (last?.status) {
      'failed' => AgentState.failed,
      'interrupted' => AgentState.interrupted,
      _ => AgentState.idle,
    };
    finishedAt = DateTime.now();
    notifyListeners();
    _finished.add(this);
  }

  /// The body the agent ran on went away: the turn will never finish.
  void markLost(String reason) {
    if (state != AgentState.running) return;
    view.addError(reason);
    state = AgentState.failed;
    finishedAt = DateTime.now();
    notifyListeners();
    _finished.add(this);
  }

  /// The latest answer: the last agent message of the last turn that has one.
  String get lastAnswer {
    for (final turn in view.turns.reversed) {
      for (final item in turn.items.reversed) {
        if (item.type == 'agentMessage' && item.displayText.trim().isNotEmpty) {
          return item.displayText;
        }
      }
    }
    return '';
  }

  /// Files changed across the conversation, with +/- line counts.
  List<String> get changedFiles {
    final out = <String, (int, int)>{};
    for (final turn in view.turns) {
      for (final item in turn.items.where((i) => i.type == 'fileChange')) {
        for (final c
            in (item.data['changes'] as List? ?? const []).cast<Map>()) {
          final diff = c['diff'] as String? ?? '';
          final add = (c['kind'] as Map?)?['type'] == 'add';
          var plus = 0, minus = 0;
          for (final line in diff.split('\n')) {
            if (add || (line.startsWith('+') && !line.startsWith('+++'))) {
              plus++;
            }
            if (!add && line.startsWith('-') && !line.startsWith('---')) {
              minus++;
            }
          }
          final prev = out[c['path'] as String] ?? (0, 0);
          out[c['path'] as String] = (prev.$1 + plus, prev.$2 + minus);
        }
      }
    }
    return [
      for (final e in out.entries) '${e.key} (+${e.value.$1} -${e.value.$2})',
    ];
  }

  List<String> get commands => [
    for (final turn in view.turns)
      for (final item in turn.items.where((i) => i.type == 'commandExecution'))
        '${item.data['command']}',
  ];

  /// The last turn's error, or the last error outside a turn (a body that
  /// went away).
  String? get lastError =>
      view.turns.lastOrNull?.error ??
      (state == AgentState.failed ? view.errors.lastOrNull : null);

  @override
  void dispose() {
    _finished.close();
    view.dispose();
    super.dispose();
  }
}
