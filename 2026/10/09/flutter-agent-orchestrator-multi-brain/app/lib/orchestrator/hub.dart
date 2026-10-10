import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../agents/agent_thread.dart';
import '../agents/backends.dart';
import '../body/body.dart';
import '../state/thread_view.dart';
import 'tools.dart';

/// The brain's settings (the orchestrator's): kept in the state folder's
/// `settings.json`, changed from any console. What runs on a body and how
/// many at once is the body's own setting (its start screen).
class HubSettings {
  /// The worker type the orchestrator runs as, on the brain's own machine.
  String orchestrator = 'codex';
  String? orchestratorModel;
  String? orchestratorEffort;

  /// Start an orchestrator turn when a worker finishes while it is idle.
  bool wakeOnFinish = true;

  Json toJson() => {
    'orchestrator': orchestrator,
    'orchestratorModel': orchestratorModel,
    'orchestratorEffort': orchestratorEffort,
    'wakeOnFinish': wakeOnFinish,
  };

  void load(Json j) {
    orchestrator = j['orchestrator'] as String? ?? 'codex';
    orchestratorModel = j['orchestratorModel'] as String?;
    orchestratorEffort = j['orchestratorEffort'] as String?;
    wakeOnFinish = j['wakeOnFinish'] as bool? ?? wakeOnFinish;
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
  String? get startupError =>
      local.startupError ??
      (local.ready && local.workerTypes.isEmpty
          ? 'Nothing can run the orchestrator on ${local.name}: turn on Codex, Claude or a custom agent on its start screen.'
          : null);
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
    if (env['ORCH_ORCHESTRATOR'] case final String p when p.isNotEmpty) {
      settings.orchestrator = p;
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

  /// Who owns each body (the signaling server's record). A brain uses only
  /// the bodies it owns; others are listed for the consoles.
  String? Function(String body) ownerOf = (_) => null;

  /// Bodies this brain may use: owned and online.
  List<Body> get ownBodies => [
    for (final b in bodies.values)
      if (b.online && ownerOf(b.name) == local.name) b,
  ];

  Body? _ownBody(String name) =>
      ownBodies.where((b) => b.name == name).firstOrNull;

  List<String> _unpaused() => [
    for (final b in ownBodies)
      if (!b.paused) b.name,
  ];

  Json _noBody(String name) => {
    'error': ownerOf(name) != null && ownerOf(name) != local.name
        ? 'body "$name" belongs to ${ownerOf(name)}, not to you'
        : 'no online body "$name" of yours',
    'your_bodies': [for (final b in ownBodies) b.name],
  };

  /// Why [body] may not go to another brain now, or null: workers of this
  /// brain run or wait there.
  String? releaseBlocker(String body) {
    final busy = workers.where(
      (w) =>
          w.body == body &&
          (w.state == AgentState.running || w.state == AgentState.queued),
    );
    return busy.isEmpty
        ? null
        : '${busy.length} worker(s) of ${local.name} running or queued on $body (${busy.map((w) => w.label).join(', ')})';
  }

  /// The roster or the owners changed.
  void ownershipChanged() {
    drainQueue();
    notifyListeners();
  }

  void addRemoteBody(RemoteBody b) {
    bodies[b.name] = b;
    b.onChanged = notifyListeners;
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
        await newConversation(workerType: a['workerType'] as String?);
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
        local.setProjectDir(a['dir'] as String);
        await newConversation();
      case 'pause':
        await setPaused(a['body'] as String, a['paused'] == true);

    }
  }

  /// Pauses or resumes one of this brain's bodies (the body keeps the
  /// state). Paused, nothing new starts there: start_thread, new turns and
  /// body tools are refused, queued workers wait; running turns finish.
  Future<void> setPaused(String name, bool paused) async {
    final body = _ownBody(name);
    if (body == null) return;
    await body.call('body/pause', {'paused': paused});
    if (!paused) drainQueue();
    notifyListeners();
  }

  /// A console's request that wants an answer (actions do not).
  Future<Object?> request(Json a) async {
    switch (a['a']) {
      case 'body':
        return bodyRequest(
          a['body'] as String,
          a['m'] as String,
          (a['p'] as Map? ?? const {}).cast<String, dynamic>(),
        );
    }
    throw StateError('unknown request ${a['a']}');
  }

  /// Threads whose body's agents restarted with new settings: they cannot
  /// take another turn.
  final _ended = <String>{};

  /// Passes a console's `body/...` request to one of this brain's bodies.
  /// New settings (`body/configure`) only while the body is paused and none
  /// of this brain's workers run or wait there: the body restarts its
  /// agents, and the threads it had end.
  Future<Object?> bodyRequest(String name, String method, Json p) async {
    if (!method.startsWith('body/')) throw StateError('not a body request: $method');
    final body = _ownBody(name);
    if (body == null) throw StateError(_noBody(name)['error'] as String);
    if (method != 'body/configure') {
      final r = await body.call(method, p);
      if (method == 'body/pause') {
        if (p['paused'] != true) drainQueue();
        notifyListeners();
      }
      return r;
    }
    if (!body.paused) throw StateError('pause $name before changing its settings');
    if (releaseBlocker(name) case final why?) throw StateError(why);
    if (body.isLocal) {
      // The orchestrator runs on this machine's agents too.
      if (orchestrator case final o? when o.isRunning || o.view.isRunning) {
        throw StateError('the orchestrator is running on $name; wait for it or stop it');
      }
      await newConversation();
    }
    final r = await body.call(method, p);
    _ended.addAll([
      for (final w in workers)
        if (w.body == name) w.label,
    ]);
    notifyListeners();
    return r;
  }

  // ---- the orchestrator -------------------------------------------------------

  AgentThread _newOrchestrator() {
    final role = AgentRole.orchestrator(
      tools: orchestratorTools,
      instructions: orchestratorInstructions(local.name),
    );
    // Falls back to another worker type when that one cannot run here.
    final available = local.workerTypes;
    if (available.isEmpty) throw StateError(startupError ?? 'no agent');
    final p = available.contains(settings.orchestrator)
        ? settings.orchestrator
        : available.first;
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
      _shownBodies = null;
      notifyListeners();
      await o.start(text);
    } else {
      await o.send(_withChanges(text));
    }
    notifyListeners();
  }

  // ---- telling the orchestrator what changed ------------------------------------

  /// What the orchestrator last saw of its bodies (list_bodies): body name
  /// to its worker types and whether it was paused. Null until it looks.
  /// Bodies change under it (a body restarts with other worker types,
  /// joins, leaves, moves to another brain, is paused or resumed); the next
  /// message it gets starts with what changed.
  Map<String, ({String types, bool paused})>? _shownBodies;

  Map<String, ({String types, bool paused})> _bodySnapshot() => {
    for (final b in ownBodies)
      b.name: (types: b.workerTypes.join(', '), paused: b.paused),
  };

  /// What changed since the orchestrator last looked, or null.
  @visibleForTesting
  String? bodiesChanged() {
    final shown = _shownBodies;
    if (shown == null) return null;
    final now = _bodySnapshot();
    String types(String t) => t.isEmpty ? 'none' : t;
    final lines = [
      for (final e in now.entries)
        if (shown[e.key] case final was?) ...[
          if (was.types != e.value.types)
            '- ${e.key}: worker types are now ${types(e.value.types)} (were ${types(was.types)})',
          if (was.paused != e.value.paused)
            e.value.paused
                ? '- ${e.key} is paused by the user: no new threads, turns or tool calls there until it is resumed (running ones finish)'
                : '- ${e.key} is resumed: you can use it again',
        ] else
          '- ${e.key} is now one of your bodies (worker types: ${types(e.value.types)}${e.value.paused ? '; paused' : ''})',
      for (final k in shown.keys)
        if (!now.containsKey(k))
          '- $k is no longer available to you (offline, or moved to another brain)',
    ];
    _shownBodies = now;
    return lines.isEmpty
        ? null
        : '[bodies changed since you last called list_bodies]\n${lines.join('\n')}';
  }

  String _withChanges(String text) {
    final c = bodiesChanged();
    return c == null ? text : '$c\n\n$text';
  }

  Future<void> interruptOrchestrator() async => orchestrator?.interrupt();

  /// A new orchestrator conversation (workers keep running).
  Future<void> newConversation({String? workerType}) async {
    if (workerType != null) {
      settings.orchestrator = workerType;
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

  int runningOn(String body, [String? type]) => workers
      .where(
        (w) =>
            w.state == AgentState.running &&
            w.body == body &&
            (type == null || w.workerType == type),
      )
      .length;

  /// The worker type's own limit on [body] (null: only the body's).
  int? typeLimit(String body, String type) =>
      (bodies[body]?.workerType(type)?['maxConcurrent'] as num?)?.toInt();

  /// Whether one more worker of [w]'s type may start on its body. The
  /// limits apply per body: each body has its own subscriptions and machine.
  bool _hasSlot(AgentThread w) {
    final body = bodies[w.body];
    if (body?.paused ?? false) return false;
    if (runningOn(w.body) >= (body?.maxWorkers ?? WorkerTypesConfig.defaultMaxWorkers)) return false;
    final limit = typeLimit(w.body, w.workerType);
    return limit == null || runningOn(w.body, w.workerType) < limit;
  }

  AgentThread? worker(String id) =>
      workers.where((w) => w.label == id).firstOrNull;

  AgentThread _createWorker(
    Body body,
    String p, {
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
      model: model ?? body.defaultModel(p),
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
          '- ${w.label} (${w.workerType} on ${w.body}) ${w.state.name}: ${w.title ?? ''}',
    ];
    _toNotify.clear();
    final text =
        '[worker update]\n${lines.join('\n')}\nUse read_thread for the details.';
    if (o.isRunning || o.view.isRunning) {
      await o.send(_withChanges(text), afterCurrentTurn: true);
    } else if (settings.wakeOnFinish) {
      await o.send(_withChanges(text));
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
    final body = _ownBody(bodyName);
    if (body == null) return ToolResult(prettyJson(_noBody(bodyName)), false);
    if (body.paused) {
      return ToolResult(prettyJson({'error': pausedMessage(bodyName)}), false);
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
        final body = _ownBody(bodyName);
        if (body == null) return _noBody(bodyName);
        if (body.paused) {
          return {'error': pausedMessage(bodyName), 'your_bodies': _unpaused()};
        }
        final p = a['worker_type'] as String? ?? '';
        if (!body.workerTypes.contains(p)) {
          final t = body.workerType(p);
          return {
            'error': t == null
                ? 'no worker type "$p" on $bodyName'
                : 'worker type "$p" is not available on $bodyName: ${t['error']}',
            'worker_types_on_$bodyName': body.workerTypes,
          };
        }
        final prompt = a['prompt'] as String;
        final w = _createWorker(
          body,
          p,
          cwd: (a['cwd'] as String?)?.isNotEmpty == true
              ? a['cwd'] as String
              : body.workerType(p)?['cwd'] as String? ?? body.projectDir,
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
          'worker_type': p,
          'model': w.model,
          'status': status,
        };
      case 'list_bodies':
        _shownBodies = _bodySnapshot();
        return {
          'bodies': [
            for (final b in ownBodies)
              {
                'body': b.name,
                'host': b.info['host'],
                'is_this_brain_machine': b.isLocal,
                'project_dir': b.projectDir,
                'running': runningOn(b.name),
                if (b.paused) 'paused': true,
                'max_concurrent': b.maxWorkers,
                'worker_types': [
                  for (final id in b.workerTypes)
                    if (b.workerType(id) case final t?)
                      {
                        'id': id,
                        'kind': t['kind'],
                        'model': b.defaultModel(id),
                        'description': t['description'],
                        'default_cwd': t['cwd'] ?? b.projectDir,
                        if ((t['extras'] as List?)?.isNotEmpty ?? false) 'can_also_use': t['extras'],
                        'max_concurrent': ?t['maxConcurrent'],
                        'running': runningOn(b.name, id),
                      },
                ],
              },
          ],
        };
      case 'send_message':
        final w = worker(a['thread_id'] as String);
        if (w == null) return {'error': 'no thread ${a['thread_id']}'};
        if (_ended.contains(w.label)) {
          return {
            'thread_id': w.label,
            'error': 'thread ${w.label} ended: the agents on ${w.body} restarted with new settings. Start a new thread.',
          };
        }
        // A new turn is new work; steering a running one is not.
        if (!w.isRunning &&
            w.state != AgentState.queued &&
            (bodies[w.body]?.paused ?? false)) {
          return {'thread_id': w.label, 'error': pausedMessage(w.body)};
        }
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
    'worker_type': w.workerType,
    'model': w.model,
    'title': w.title,
    'status': w.state.name,
    if (_ended.contains(w.label)) 'ended': 'the agents on ${w.body} restarted with new settings',
    if (w.state == AgentState.queued && (bodies[w.body]?.paused ?? false))
      'waiting_for': '${w.body} to be resumed (paused by the user)',
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
