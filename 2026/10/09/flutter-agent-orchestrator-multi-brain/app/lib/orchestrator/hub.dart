import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../agents/agent_check.dart';
import '../rpc/rpc_client.dart' show RpcClient;
import '../agents/agent_thread.dart';
import '../agents/backends.dart';
import '../body/body.dart';
import '../state/thread_view.dart';
import 'brain_agent.dart';
import 'brain_config.dart';
import 'tools.dart';

/// A brain: owns the orchestrator and the ledger of workers on the bodies
/// it is linked to ([RemoteBody]s, its own app's body among them: every body
/// is reached over its link). An app may run several. The user talks to the
/// orchestrator only (from any app's console); the orchestrator drives
/// workers through [tools].
class Hub extends ChangeNotifier {
  Hub({
    required this.name,
    required this.stateDir,
    this.defaultDir,
    void Function(RpcClient client)? log,
  }) {
    brain = BrainAgent(
      stateDir: stateDir,
      onTool: _onTool,
      onUserPrompt: notifyListeners,
      log: log,
    )..addListener(notifyListeners);
  }

  /// This brain's name in the roster.
  String name;

  /// Its own folder: `brain.json`, its custom agent's CODEX_HOME.
  final String stateDir;

  /// Where the orchestrator works when it sets no folder (the app's project
  /// folder, if the app is a body).
  final String Function()? defaultDir;

  String get _defaultDir =>
      defaultDir?.call() ??
      Platform.environment['ORCH_CWD'] ??
      Platform.environment['HOME'] ??
      '/';

  /// The orchestrator's own agent, apart from the body's.
  late final BrainAgent brain;
  BrainConfig get config => brain.config;

  /// Every body by name. Bodies that went away
  /// stay listed as offline until one with the same name joins.
  final bodies = <String, Body>{};

  bool get ready => brain.ready;
  String? get startupError => brain.ready ? brain.error : null;

  /// Where the orchestrator works: its own folder, else this machine's
  /// project folder.
  String get projectDir => expandHome(config.cwd) ?? _defaultDir;

  AgentThread? orchestrator;
  final workers = <AgentThread>[];
  int _seq = 0;

  String get _stateDir => stateDir;

  Future<void> start() async {
    BrainConfig c;
    try {
      c = BrainConfig.load(_stateDir, Platform.environment);
    } catch (e) {
      c = BrainConfig();
    }
    brain.config = c;
    await brain.start(c, cwd: projectDir);
  }

  /// New settings for the brain (start screen or a console): saved, and the
  /// orchestrator's agent restarts. Only while it is not running; the next
  /// message starts a new conversation. Workers keep running.
  Future<void> configure(BrainConfig c) async {
    if (c.problem case final p?) throw StateError(p);
    if (orchestrator case final o? when o.isRunning || o.view.isRunning) {
      throw StateError('the orchestrator is running; wait for it or stop it');
    }
    await newConversation();
    c.save(_stateDir);
    await brain.restart(c, cwd: expandHome(c.cwd) ?? _defaultDir);
    notifyListeners();
  }

  /// The brains each body belongs to (the signaling server's record). A
  /// brain uses only its bodies; others are listed for the consoles. A body
  /// shared with other brains is used by one of them at a time.
  List<String> Function(String body) ownersOf = (_) => const [];

  /// Bodies this brain may use: its own and online.
  List<Body> get ownBodies => [
    for (final b in bodies.values)
      if (b.online && ownersOf(b.name).contains(name)) b,
  ];

  /// The other brain using [b] now, or null (free, or this brain's).
  String? heldByOther(Body b) =>
      b.heldBy != null && b.heldBy != name ? b.heldBy : null;

  Body? _ownBody(String name) =>
      ownBodies.where((b) => b.name == name).firstOrNull;

  /// Bodies where this brain can start work now.
  List<String> _usable() => [
    for (final b in ownBodies)
      if (!b.paused && heldByOther(b) == null) b.name,
  ];

  Json _noBody(String name) => {
    'error': ownersOf(name).isNotEmpty && !ownersOf(name).contains(name)
        ? 'body "$name" belongs to ${ownersOf(name).join(', ')}, not to you'
        : 'no online body "$name" of yours',
    'your_bodies': [for (final b in ownBodies) b.name],
  };

  /// Why [body] may not stop belonging to this brain now, or null: workers
  /// of this brain run or wait there.
  String? releaseBlocker(String body) {
    final busy = workers.where(
      (w) =>
          w.body == body &&
          (w.state == AgentState.running || w.state == AgentState.queued),
    );
    return busy.isEmpty
        ? null
        : '${busy.length} worker(s) of $name running or queued on $body (${busy.map((w) => w.label).join(', ')})';
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
        await newConversation();
      case 'stop':
        if (worker(a['id'] as String) case final w?) await stopWorker(w);
      case 'answer':
        answer(a['requestId'] as Object, a['result']);
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
      case 'brain':
        final p = (a['p'] as Map? ?? const {}).cast<String, dynamic>();
        switch (a['m']) {
          case 'brain/config':
            return {
              'config': config.toJson(),
              'projectDirDefault': _defaultDir,
            };
          case 'brain/check':
            return runCheck(
              const AgentChecker(),
              p['what'] as String,
              (p['args'] as Map? ?? const {}).cast<String, dynamic>(),
            );
          case 'brain/configure':
            await configure(BrainConfig.fromJson((p['config'] as Map).cast()));
            return null;
        }
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
    if (!method.startsWith('body/')) {
      throw StateError('not a body request: $method');
    }
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
    if (!body.paused) {
      throw StateError('pause $name before changing its settings');
    }
    if (releaseBlocker(name) case final why?) throw StateError(why);
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
      instructions: orchestratorInstructions(name),
    );
    final agent = brain.create(cwd: projectDir, role: role);
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
  Map<String, ({String types, bool paused, String? inUseBy})>? _shownBodies;

  Map<String, ({String types, bool paused, String? inUseBy})> _bodySnapshot() => {
    for (final b in ownBodies)
      b.name: (
        types: b.workerTypes.join(', '),
        paused: b.paused,
        inUseBy: heldByOther(b),
      ),
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
          if (was.inUseBy != e.value.inUseBy)
            e.value.inUseBy != null
                ? '- ${e.key} is now in use by ${e.value.inUseBy}: you can only read there until its workers finish'
                : '- ${e.key} is free again: you can start work there',
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
  Future<void> newConversation() async {
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
    brain.answer(requestId, result);
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
    if (body != null && heldByOther(body) != null) return false;
    if (runningOn(w.body) >=
        (body?.maxWorkers ?? WorkerTypesConfig.defaultMaxWorkers)) {
      return false;
    }
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
      _letGo(w);
      rethrow;
    }
    return 'running';
  }

  /// A worker that will not run: the body stops counting it as holding the
  /// body (a remote body hears it through `agent/close`).
  void _letGo(AgentThread w) {
    if (bodies[w.body] case final LocalBody b) {
      b.release(w);
    } else {
      unawaited(w.close().catchError((_) {}));
    }
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
      // It was made on the body: let it go, so it no longer holds the body.
      _letGo(w);
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
    } else if (config.wakeOnFinish) {
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

  /// A tool call without an orchestrator (`ORCH_TOOLS`): the result as the
  /// orchestrator would read it, images left out.
  Future<Json> toolResult(String tool, Json args) async {
    final o = orchestrator;
    if (tool == 'fetch_image' && o == null) {
      // fetch_image shows the image in a conversation; without one, read it.
      final body = _ownBody(args['body'] as String? ?? '');
      if (body == null) return _noBody(args['body'] as String? ?? '');
      if (body.paused) return {'error': pausedMessage(body.name)};
      try {
        final image = await body.readImage(args['path'] as String);
        return {'width': image['width'], 'height': image['height'], 'bytes': image['bytes']};
      } catch (e) {
        return {'error': '$e'};
      }
    }
    return callTool(tool, args);
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
          return {'error': pausedMessage(bodyName), 'usable_bodies': _usable()};
        }
        if (heldByOther(body) case final h?) {
          return {'error': inUseMessage(bodyName, h), 'usable_bodies': _usable()};
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
                'is_this_brain_machine': b.info['host'] == thisHost,
                'project_dir': b.projectDir,
                'running': runningOn(b.name),
                if (b.paused) 'paused': true,
                if (ownersOf(b.name).length > 1)
                  'shared_with': [
                    for (final o in ownersOf(b.name))
                      if (o != name) o,
                  ],
                if (heldByOther(b) case final h?) ...{
                  'in_use_by': h,
                  'their_work': [
                    for (final a in b.activity)
                      if (a['brain'] == h)
                        {
                          'thread': a['thread'],
                          'worker_type': a['workerType'],
                          'title': a['title'],
                          'state': a['state'],
                        },
                  ],
                },
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
                        if ((t['extras'] as List?)?.isNotEmpty ?? false)
                          'can_also_use': t['extras'],
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
            'error':
                'thread ${w.label} ended: the agents on ${w.body} restarted with new settings. Start a new thread.',
          };
        }
        // A new turn is new work; steering a running one is not.
        if (!w.isRunning && w.state != AgentState.queued) {
          final b = bodies[w.body];
          if (b?.paused ?? false) {
            return {'thread_id': w.label, 'error': pausedMessage(w.body)};
          }
          if (b != null && heldByOther(b) != null) {
            return {'thread_id': w.label, 'error': inUseMessage(w.body, heldByOther(b)!)};
          }
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
    if (_ended.contains(w.label))
      'ended': 'the agents on ${w.body} restarted with new settings',
    if (w.state == AgentState.queued && (bodies[w.body]?.paused ?? false))
      'waiting_for': '${w.body} to be resumed (paused by the user)'
    else if (w.state == AgentState.queued &&
        bodies[w.body] != null &&
        heldByOther(bodies[w.body]!) != null)
      'waiting_for': '${heldByOther(bodies[w.body]!)} to finish on ${w.body}',
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
    brain.dispose();
    super.dispose();
  }
}

/// This machine's short host name (bodies report theirs).
final thisHost = Platform.localHostname.split('.').first;
