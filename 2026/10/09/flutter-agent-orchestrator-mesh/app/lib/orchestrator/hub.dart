import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../agents/agent_thread.dart';
import '../agents/backends.dart';
import '../body/body.dart';
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

/// The brain: owns the orchestrator and the ledger of workers on every body
/// (this app's [local] one and the connected [RemoteBody]s). The user talks
/// to the orchestrator only (from any app's console); the orchestrator
/// drives workers through [tools].
class Hub extends ChangeNotifier {
  Hub(this.local) {
    local
      ..toolHandler = _onTool
      ..onUserPrompt = notifyListeners
      ..addListener(notifyListeners);
    bodies[local.name] = local;
  }

  final LocalBody local;
  final settings = HubSettings();

  /// Every body by name, the brain's own included. Bodies that went away
  /// stay listed as offline until one with the same name joins.
  final bodies = <String, Body>{};

  bool get ready => local.ready;
  String? get startupError => local.startupError;
  String get projectDir => local.projectDir;

  AgentThread? orchestrator;
  final workers = <AgentThread>[];
  int _seq = 0;

  String get _stateDir => local.stateDir;

  File get _settingsFile => File('$_stateDir/settings.json');

  Future<void> start() async {
    if (await _settingsFile.exists()) {
      settings.load(jsonDecode(await _settingsFile.readAsString()) as Json);
    }
    final env = Platform.environment;
    if (env['ORCH_PROVIDER'] case final String p when p.isNotEmpty) {
      settings.orchestrator = Provider.parse(p);
    }
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await _settingsFile.parent.create(recursive: true);
    await _settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
    notifyListeners();
  }

  /// A name for a joining body: the one it asked for unless an online body
  /// has it.
  String claimName(String requested) {
    var name = requested;
    for (var i = 2; bodies[name]?.online == true; i++) {
      name = '$requested-$i';
    }
    return name;
  }

  void addRemoteBody(RemoteBody b) {
    bodies[b.name] = b;
    b
      ..onChanged = notifyListeners
      ..onAction = handleAction;
    b.peer.closed.then((_) {
      b.lost();
      notifyListeners();
    });
    notifyListeners();
  }

  /// Console actions, from this app's console or a body's.
  Future<void> handleAction(Json a) async {
    switch (a['a']) {
      case 'send':
        await sendToOrchestrator(a['text'] as String);
      case 'interrupt':
        await interruptOrchestrator();
      case 'new':
        await newConversation(
          provider: a['provider'] == null
              ? null
              : Provider.parse(a['provider'] as String),
        );
      case 'stop':
        if (worker(a['id'] as String) case final w?) await stopWorker(w);
      case 'settings':
        settings.load((a['settings'] as Map).cast<String, dynamic>());
        await saveSettings();
        // A higher limit may let queued workers start.
        drainQueue();
      case 'answer':
        answer(a['requestId'] as Object, a['result']);
      case 'project':
        local.projectDir = a['dir'] as String;
        await newConversation();
    }
  }

  // ---- the orchestrator -------------------------------------------------------

  AgentThread _newOrchestrator() {
    final role = AgentRole.orchestrator(
      tools: orchestratorTools,
      instructions: orchestratorInstructions(local.name),
    );
    // kiapi falls back to Codex when its app-server did not start.
    final p = local.providers.contains(settings.orchestrator)
        ? settings.orchestrator
        : Provider.codex;
    final model =
        settings.orchestratorModel != null &&
            local.modelsFor(p).any((m) => m['id'] == settings.orchestratorModel)
        ? settings.orchestratorModel
        : local.defaultModel(p);
    final agent = local.create(
      p,
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
    notifyListeners();
    if (old != null) {
      await old.interrupt();
      await old.close();
    }
  }

  /// An answer to the orchestrator's question (Claude's AskUserQuestion).
  void answer(Object requestId, Object? result) {
    local.answer(requestId, result);
    final o = orchestrator;
    if (o == null) return;
    for (final r in List.of(o.view.pending)) {
      if (r.request.id == requestId) o.view.removePending(r);
    }
  }

  // ---- workers ----------------------------------------------------------------

  int get runningCount =>
      workers.where((w) => w.state == AgentState.running).length;

  int runningOn(String body, [Provider? p]) => workers
      .where(
        (w) =>
            w.state == AgentState.running &&
            w.body == body &&
            (p == null || w.provider == p),
      )
      .length;

  /// Whether one more worker of [w]'s provider may start on its body. The
  /// limits apply per body: each body has its own subscriptions and machine.
  bool _hasSlot(AgentThread w) =>
      runningOn(w.body) < settings.maxConcurrent &&
      (w.provider != Provider.kiapi ||
          runningOn(w.body, Provider.kiapi) < settings.kiapiMaxConcurrent);

  AgentThread? worker(String id) =>
      workers.where((w) => w.label == id).firstOrNull;

  AgentThread _createWorker(
    Body body,
    Provider p, {
    required String cwd,
    String? title,
    String? model,
  }) {
    final label = 'w${++_seq}';
    final agent = body.create(
      p,
      label: label,
      cwd: cwd,
      role: const AgentRole.worker(),
      title: title,
      model: model ?? settings.workerModel[p] ?? body.defaultModel(p),
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
    if (!_hasSlot(w)) {
      w
        ..state = AgentState.queued
        ..pendingText = text;
      notifyListeners();
      return 'queued';
    }
    w.pendingText = null;
    // Take the slot now: drainQueue starts several workers without awaiting.
    w.markRunning();
    try {
      if (w.backendId == null) {
        await w.start(text);
      } else {
        await w.send(text);
      }
    } catch (e) {
      w.markLost('$e');
      rethrow;
    }
    return 'running';
  }

  void drainQueue() {
    for (final w
        in workers.where((w) => w.state == AgentState.queued).toList()) {
      if (bodies[w.body]?.online != true) continue;
      if (!_hasSlot(w)) continue;
      final text = w.pendingText;
      if (text != null) unawaited(_run(w, text).catchError((_) => 'failed'));
    }
  }

  /// Stops a worker from a console or the orchestrator: interrupts a running
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
          '- ${w.label} (${w.provider.name} on ${w.body}) ${w.state.name}: ${w.title ?? ''}',
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

  Future<ToolResult> _onTool(AgentThread caller, String tool, Json args) async {
    if (tool == 'fetch_image') return _fetchImage(caller, args);
    final result = await callTool(tool, args);
    notifyListeners();
    return ToolResult(prettyJson(result), !result.containsKey('error'));
  }

  /// Brings an image file from a body to the orchestrator (as an image it
  /// can look at) and into the transcript (so every console shows it).
  Future<ToolResult> _fetchImage(AgentThread caller, Json a) async {
    final bodyName = a['body'] as String? ?? '';
    final path = a['path'] as String? ?? '';
    final body = bodies[bodyName];
    if (body == null || !body.online) {
      return ToolResult(
        prettyJson({
          'error': 'no online body "$bodyName"',
          'bodies': [
            for (final b in bodies.values)
              if (b.online) b.name,
          ],
        }),
        false,
      );
    }
    final Json image;
    try {
      image = await body.readImage(path);
    } catch (e) {
      return ToolResult(prettyJson({'error': '$e'}), false);
    }
    caller.view.attachImage({...image, 'body': bodyName});
    notifyListeners();
    return ToolResult(
      prettyJson({
        'body': bodyName,
        'path': path,
        'width': image['width'],
        'height': image['height'],
        'original_width': image['originalWidth'],
        'original_height': image['originalHeight'],
        'shown_to_user': true,
      }),
      true,
      [image],
    );
  }

  Future<Json> callTool(String tool, Json a) async {
    switch (tool) {
      case 'start_thread':
        final bodyName = a['body'] as String? ?? '';
        final body = bodies[bodyName];
        if (body == null || !body.online) {
          return {
            'error': 'no online body "$bodyName"',
            'bodies': [
              for (final b in bodies.values)
                if (b.online) b.name,
            ],
          };
        }
        final p = Provider.parse(a['provider'] as String);
        if (!body.providers.contains(p)) {
          return {
            'error': '${p.name} is not available on $bodyName',
            'providers': [for (final p in body.providers) p.name],
          };
        }
        final prompt = a['prompt'] as String;
        final w = _createWorker(
          body,
          p,
          cwd: (a['cwd'] as String?)?.isNotEmpty == true
              ? a['cwd'] as String
              : body.projectDir,
          title: a['title'] as String? ?? _firstLine(prompt),
          model: a['model'] as String?,
        );
        String status;
        try {
          status = await _run(w, prompt);
        } catch (e) {
          return {'thread_id': w.label, 'error': '$e'};
        }
        return {
          'thread_id': w.label,
          'body': w.body,
          'provider': p.name,
          'model': w.model,
          'status': status,
        };
      case 'list_bodies':
        return {
          'max_concurrent_per_body': settings.maxConcurrent,
          'kiapi_max_concurrent_per_body': settings.kiapiMaxConcurrent,
          'bodies': [
            for (final b in bodies.values)
              {
                'body': b.name,
                'host': b.info['host'],
                'online': b.online,
                'is_brain': b.isLocal,
                'providers': [for (final p in b.providers) p.name],
                'project_dir': b.projectDir,
                'running': runningOn(b.name),
              },
          ],
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
          'max_concurrent_per_body': settings.maxConcurrent,
          'kiapi_max_concurrent_per_body': settings.kiapiMaxConcurrent,
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
            if (!busy(w)) 'error': ?w.lastError,
          },
      ],
    };
  }

  Json _summary(AgentThread w) => {
    'thread_id': w.label,
    'body': w.body,
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
    local.closeBackends();
    super.dispose();
  }
}
