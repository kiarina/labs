import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../agents/agent_thread.dart';
import '../agents/backends.dart';
import '../rpc/rpc_client.dart';
import '../state/thread_view.dart';
import 'tools.dart';

/// Settings the user can change; kept in
/// `~/Library/Application Support/<bundle id>/settings.json`.
class HubSettings {
  Provider orchestrator = Provider.codex;

  /// Workers allowed to run at once; more are queued.
  int maxConcurrent = 4;

  /// kiapi workers allowed to run at once (kiapi serves one request at a
  /// time, so more would only wait inside kiapi).
  int kiapiMaxConcurrent = 1;

  /// Start an orchestrator turn when a worker finishes while it is idle.
  bool wakeOnFinish = true;

  String? orchestratorModel;
  String? orchestratorEffort;

  /// Default models for workers, per provider (the orchestrator may pick).
  final workerModel = <Provider, String?>{};

  Json toJson() => {
    'orchestrator': orchestrator.name,
    'maxConcurrent': maxConcurrent,
    'kiapiMaxConcurrent': kiapiMaxConcurrent,
    'wakeOnFinish': wakeOnFinish,
    'orchestratorModel': orchestratorModel,
    'orchestratorEffort': orchestratorEffort,
    'workerModel': {for (final e in workerModel.entries) e.key.name: e.value},
  };

  void load(Json j) {
    orchestrator = Provider.parse(j['orchestrator'] as String? ?? 'codex');
    maxConcurrent = (j['maxConcurrent'] as num?)?.toInt() ?? maxConcurrent;
    kiapiMaxConcurrent =
        (j['kiapiMaxConcurrent'] as num?)?.toInt() ?? kiapiMaxConcurrent;
    wakeOnFinish = j['wakeOnFinish'] as bool? ?? wakeOnFinish;
    orchestratorModel = j['orchestratorModel'] as String?;
    orchestratorEffort = j['orchestratorEffort'] as String?;
    for (final e in (j['workerModel'] as Map? ?? const {}).entries) {
      workerModel[Provider.parse(e.key as String)] = e.value as String?;
    }
  }
}

/// Owns the backends, the orchestrator and its workers. The user talks to
/// the orchestrator only; the orchestrator drives workers through [tools].
class Hub extends ChangeNotifier {
  late final CodexBackend codex;
  late final ClaudeBackend claude;

  /// A second Codex app-server whose model provider is kiapi. Null when it
  /// failed to start ([kiapiError]); the other providers still work.
  CodexBackend? kiapi;
  String? kiapiError;
  final settings = HubSettings();
  String? startupError;
  bool ready = false;

  String projectDir =
      Platform.environment['ORCH_CWD'] ?? Platform.environment['HOME'] ?? '/';

  AgentThread? orchestrator;
  final workers = <AgentThread>[];
  int _seq = 0;

  /// The thread shown in the center (the orchestrator unless the user opened
  /// a worker).
  AgentThread? viewing;

  final protocolLog = <ProtocolLogEntry>[];

  String get _stateDir {
    final env = Platform.environment;
    return env['ORCH_STATE_DIR'] ??
        '${env['HOME']}/Library/Application Support/com.kiarina.labs.agentOrchestratorKiapi';
  }

  File get _settingsFile => File('$_stateDir/settings.json');

  Future<void> start() async {
    try {
      if (await _settingsFile.exists()) {
        settings.load(jsonDecode(await _settingsFile.readAsString()) as Json);
      }
      final env = Platform.environment;
      if (env['ORCH_PROVIDER'] case final String p when p.isNotEmpty) {
        settings.orchestrator = Provider.parse(p);
      }
      codex = CodexBackend(await codexAppServer(), onTool: _onTool)
        ..onChanged = notifyListeners;
      claude = ClaudeBackend(claudeBridge(), onTool: _onTool)
        ..onChanged = notifyListeners
        ..onUserPrompt = (_, _) => notifyListeners();
      for (final c in [codex.client, claude.client]) {
        c.log.listen((e) {
          protocolLog.add(e);
          if (protocolLog.length > 3000) protocolLog.removeRange(0, 1000);
        });
      }
      await Future.wait([
        codex.start(),
        claude.start(projectDir),
        _startKiapi(),
      ]);
      ready = true;
      notifyListeners();
    } catch (e) {
      startupError = '$e';
      notifyListeners();
    }
  }

  Future<void> _startKiapi() async {
    try {
      final k = CodexBackend(
        await kiapiAppServer(_stateDir),
        onTool: _onTool,
        provider: Provider.kiapi,
      )..onChanged = notifyListeners;
      k.client.log.listen((e) {
        protocolLog.add(e);
        if (protocolLog.length > 3000) protocolLog.removeRange(0, 1000);
      });
      await k.start();
      kiapi = k;
    } catch (e) {
      kiapiError = '$e';
    }
  }

  /// Providers whose backend is up.
  List<Provider> get providers => [
    Provider.codex,
    Provider.claude,
    if (kiapi != null) Provider.kiapi,
  ];

  Future<void> saveSettings() async {
    await _settingsFile.parent.create(recursive: true);
    await _settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
    notifyListeners();
  }

  List<Json> modelsFor(Provider p) => switch (p) {
    Provider.codex => codex.models,
    Provider.claude => claude.models,
    Provider.kiapi => kiapi?.models ?? const [],
  };

  String? _backendDefaultModel(Provider p) => switch (p) {
    Provider.codex => codex.defaultModel,
    Provider.claude => claude.defaultModel,
    Provider.kiapi => kiapi?.defaultModel,
  };

  String? defaultModelFor(Provider p) =>
      settings.workerModel[p] ?? _backendDefaultModel(p);

  // ---- the orchestrator -------------------------------------------------------

  AgentThread _newOrchestrator() {
    final role = AgentRole.orchestrator(
      tools: orchestratorTools,
      instructions: orchestratorInstructions,
    );
    final p = settings.orchestrator;
    final model =
        settings.orchestratorModel != null &&
            modelsFor(p).any((m) => m['id'] == settings.orchestratorModel)
        ? settings.orchestratorModel
        : _backendDefaultModel(p);
    final agent = p == Provider.codex
        ? codex.create(
            label: 'orchestrator',
            cwd: projectDir,
            role: role,
            model: model,
            effort: settings.orchestratorEffort,
          )
        : claude.create(
            label: 'orchestrator',
            cwd: projectDir,
            role: role,
            model: model,
            effort: settings.orchestratorEffort,
          );
    agent.addListener(notifyListeners);
    return agent;
  }

  Future<void> sendToOrchestrator(String text) async {
    viewing = null;
    var o = orchestrator;
    if (o == null) {
      o = _newOrchestrator();
      orchestrator = o;
      notifyListeners();
      await o.start(text);
    } else {
      await o.send(text);
    }
    notifyListeners();
  }

  Future<void> interruptOrchestrator() async => orchestrator?.interrupt();

  /// A new orchestrator conversation (workers keep running).
  Future<void> newConversation({Provider? provider}) async {
    if (provider != null) {
      settings.orchestrator = provider;
      await saveSettings();
    }
    final old = orchestrator;
    orchestrator = null;
    viewing = null;
    notifyListeners();
    if (old != null) {
      await old.interrupt();
      await old.close();
    }
  }

  void view(AgentThread? agent) {
    viewing = agent;
    notifyListeners();
  }

  void answer(PendingRequest r, Object? result) {
    claude.client.respond(r.request.id, result);
    orchestrator?.view.removePending(r);
  }

  // ---- workers ----------------------------------------------------------------

  int get runningCount =>
      workers.where((w) => w.state == AgentState.running).length;

  int runningFor(Provider p) => workers
      .where((w) => w.state == AgentState.running && w.provider == p)
      .length;

  /// Whether one more worker of [p] may start now.
  bool _hasSlot(Provider p) =>
      runningCount < settings.maxConcurrent &&
      (p != Provider.kiapi || runningFor(p) < settings.kiapiMaxConcurrent);

  AgentThread? worker(String id) =>
      workers.where((w) => w.label == id).firstOrNull;

  AgentThread _createWorker(
    Provider p, {
    required String cwd,
    String? title,
    String? model,
  }) {
    final label = 'w${++_seq}';
    final m = model ?? defaultModelFor(p);
    final codexLike = switch (p) {
      Provider.codex => codex,
      Provider.kiapi => kiapi,
      Provider.claude => null,
    };
    final agent = codexLike != null
        ? codexLike.create(
            label: label,
            cwd: cwd,
            role: const AgentRole.worker(),
            title: title,
            model: m,
          )
        : claude.create(
            label: label,
            cwd: cwd,
            role: const AgentRole.worker(),
            title: title,
            model: m,
          );
    agent.addListener(notifyListeners);
    agent.finished.listen(_onWorkerFinished);
    workers.add(agent);
    return agent;
  }

  /// Starts or continues a worker now, or queues it when the limit is reached.
  Future<String> _run(AgentThread w, String text) async {
    if (w.isRunning) {
      await w.send(text);
      return 'steered';
    }
    if (!_hasSlot(w.provider)) {
      w
        ..state = AgentState.queued
        ..pendingText = text;
      notifyListeners();
      return 'queued';
    }
    w.pendingText = null;
    // Take the slot now: drainQueue starts several workers without awaiting.
    w.markRunning();
    if (w.backendId == null) {
      await w.start(text);
    } else {
      await w.send(text);
    }
    return 'running';
  }

  void drainQueue() {
    for (final w
        in workers.where((w) => w.state == AgentState.queued).toList()) {
      if (runningCount >= settings.maxConcurrent) break;
      if (!_hasSlot(w.provider)) continue;
      final text = w.pendingText;
      if (text != null) unawaited(_run(w, text));
    }
  }

  /// Stops a worker from the UI or the orchestrator: interrupts a running
  /// turn, or takes a queued one off the queue.
  Future<String> stopWorker(AgentThread w) async {
    if (w.state == AgentState.queued) {
      w
        ..state = AgentState.cancelled
        ..pendingText = null;
      notifyListeners();
      return 'cancelled';
    }
    if (w.isRunning) {
      await w.interrupt();
      return 'interrupting';
    }
    return w.state.name;
  }

  // Completion notices for the orchestrator, batched for a moment so that
  // several workers finishing together become one message.
  final _waiting = <Completer<void>>[];
  final _waitedIds = <String>{};
  final _toNotify = <String>[];
  Timer? _notifyTimer;

  void _onWorkerFinished(AgentThread w) {
    notifyListeners();
    drainQueue();
    for (final c in List.of(_waiting)) {
      if (!c.isCompleted) c.complete();
    }
    if (_waitedIds.contains(w.label)) return; // wait_threads reports it.
    _toNotify.add(w.label);
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 1500), _flushNotices);
  }

  Future<void> _flushNotices() async {
    final o = orchestrator;
    if (o == null || _toNotify.isEmpty) return;
    final lines = [
      for (final id in _toNotify)
        if (worker(id) case final w?)
          '- ${w.label} (${w.provider.name}) ${w.state.name}: ${w.title ?? ''}',
    ];
    _toNotify.clear();
    final text =
        '[worker update]\n${lines.join('\n')}\nUse read_thread for the details.';
    if (o.isRunning || o.view.isRunning) {
      await o.send(text, afterCurrentTurn: true);
    } else if (settings.wakeOnFinish) {
      await o.send(text);
    }
  }

  // ---- tool calls ---------------------------------------------------------------

  Future<(String, bool)> _onTool(
    AgentThread caller,
    String tool,
    Json args,
  ) async {
    final result = await callTool(tool, args);
    notifyListeners();
    return (prettyJson(result), !result.containsKey('error'));
  }

  Future<Json> callTool(String tool, Json a) async {
    switch (tool) {
      case 'start_thread':
        final p = Provider.parse(a['provider'] as String);
        if (p == Provider.kiapi && kiapi == null) {
          return {'error': 'kiapi is not available: $kiapiError'};
        }
        final prompt = a['prompt'] as String;
        final w = _createWorker(
          p,
          cwd: (a['cwd'] as String?)?.isNotEmpty == true
              ? a['cwd'] as String
              : projectDir,
          title: a['title'] as String? ?? _firstLine(prompt),
          model: a['model'] as String?,
        );
        final status = await _run(w, prompt);
        return {
          'thread_id': w.label,
          'provider': p.name,
          'model': w.model,
          'status': status,
        };
      case 'send_message':
        final w = worker(a['thread_id'] as String);
        if (w == null) return {'error': 'no thread ${a['thread_id']}'};
        return {
          'thread_id': w.label,
          'status': await _run(w, a['message'] as String),
        };
      case 'wait_threads':
        return _wait(a);
      case 'read_thread':
        final w = worker(a['thread_id'] as String);
        if (w == null) return {'error': 'no thread ${a['thread_id']}'};
        return _describe(w, full: a['detail'] == 'full');
      case 'interrupt_thread':
        final w = worker(a['thread_id'] as String);
        if (w == null) return {'error': 'no thread ${a['thread_id']}'};
        return {'thread_id': w.label, 'status': await stopWorker(w)};
      case 'list_threads':
        return {
          'max_concurrent': settings.maxConcurrent,
          'kiapi_max_concurrent': settings.kiapiMaxConcurrent,
          'running': runningCount,
          'threads': [for (final w in workers) _summary(w)],
        };
      default:
        return {'error': 'unknown tool $tool'};
    }
  }

  Future<Json> _wait(Json a) async {
    final ids =
        (a['thread_ids'] as List?)?.cast<String>() ??
        [
          for (final w in workers)
            if (w.state == AgentState.running || w.state == AgentState.queued)
              w.label,
        ];
    final all = a['mode'] == 'all';
    final timeout = Duration(
      seconds: ((a['timeout_seconds'] as num?)?.toInt() ?? 120).clamp(1, 600),
    );
    final targets = [for (final id in ids) ?worker(id)];
    bool busy(AgentThread w) =>
        w.state == AgentState.running || w.state == AgentState.queued;
    bool done() =>
        all ? targets.every((w) => !busy(w)) : targets.any((w) => !busy(w));
    final deadline = DateTime.now().add(timeout);
    _waitedIds.addAll(ids);
    try {
      while (targets.isNotEmpty &&
          !done() &&
          DateTime.now().isBefore(deadline)) {
        final c = Completer<void>();
        _waiting.add(c);
        await c.future.timeout(
          deadline.difference(DateTime.now()),
          onTimeout: () {},
        );
        _waiting.remove(c);
      }
    } finally {
      _waitedIds.removeAll(ids);
    }
    return {
      'timed_out': targets.isNotEmpty && !done(),
      'threads': [
        for (final w in targets)
          {
            ..._summary(w),
            if (!busy(w)) 'last_answer': _clip(w.lastAnswer, 1500),
          },
      ],
    };
  }

  Json _summary(AgentThread w) => {
    'thread_id': w.label,
    'provider': w.provider.name,
    'model': w.model,
    'title': w.title,
    'status': w.state.name,
    'cwd': w.cwd,
    if (w.turnStartedAt != null)
      'seconds':
          (w.finishedAt != null && !w.isRunning
                  ? w.finishedAt!
                  : DateTime.now())
              .difference(w.turnStartedAt!)
              .inSeconds,
  };

  Json _describe(AgentThread w, {required bool full}) => {
    ..._summary(w),
    'last_answer': _clip(w.lastAnswer, full ? 12000 : 4000),
    'files_changed': w.changedFiles,
    'commands_run': w.commands.length,
    'last_commands': w.commands.reversed.take(5).toList().reversed.toList(),
    'error': ?w.lastError,
    if (full) 'transcript': _clip(_transcript(w), 20000),
  };

  String _transcript(AgentThread w) {
    final b = StringBuffer();
    for (final turn in w.view.turns) {
      for (final i in turn.items) {
        switch (i.type) {
          case 'userMessage':
            final c = (i.data['content'] as List? ?? const []).cast<Map>();
            b.writeln('USER: ${c.map((e) => e['text'] ?? '').join(' ')}');
          case 'agentMessage':
            b.writeln('AGENT: ${i.displayText}');
          case 'commandExecution':
            b.writeln(
              '\$ ${i.data['command']}\n${_clip(i.commandOutput, 800)}',
            );
          case 'fileChange':
            b.writeln(
              'EDIT ${(i.data['changes'] as List? ?? const []).map((c) => c['path']).join(', ')}',
            );
        }
      }
      b.writeln('--- turn ${turn.status}');
    }
    return b.toString();
  }

  static String _clip(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  static String _firstLine(String s) {
    final l = s.trim().split('\n').first;
    return l.length > 60 ? '${l.substring(0, 60)}…' : l;
  }

  @override
  void dispose() {
    kiapi?.client.dispose();
    codex.client.dispose();
    claude.client.dispose();
    super.dispose();
  }
}
