import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../agents/agent_thread.dart';
import '../agents/backends.dart';
import '../mesh/peer.dart';
import '../rpc/rpc_client.dart';
import '../state/thread_view.dart' show Json;

/// Where agents run: this app's own backends ([LocalBody]) or another app's,
/// reached over a data channel ([RemoteBody]). The brain starts workers on
/// any body by name.
abstract mixin class Body {
  String get name;
  bool get online;

  /// This app's own backends (the brain's body, for the brain).
  bool get isLocal;

  /// What the body reports about itself: host, worker types, project
  /// directory, models, subscription usage.
  Json get info;

  /// Every worker type the body offers, available or not (`error`).
  List<Json> get workerTypeInfo => [
    for (final t in (info['workerTypes'] as List? ?? const []))
      (t as Map).cast<String, dynamic>(),
  ];

  /// The ids of the worker types that can run now.
  List<String> get workerTypes => [
    for (final t in workerTypeInfo)
      if (t['error'] == null) t['id'] as String,
  ];

  Json? workerType(String id) =>
      workerTypeInfo.where((t) => t['id'] == id).firstOrNull;

  String labelOf(String id) => workerType(id)?['label'] as String? ?? id;

  String get projectDir => info['projectDir'] as String? ?? '/';

  List<Json> modelsFor(String type) =>
      ((info['models'] as Map?)?[type] as List? ?? const [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();

  String? defaultModel(String type) =>
      (info['defaultModels'] as Map?)?[type] as String?;

  /// An image file on this body's machine, scaled down for sending
  /// ([loadImage]).
  Future<Json> readImage(String path);

  /// A new agent on this body; it starts when [AgentThread.start] is called.
  AgentThread create(
    String type, {
    required String label,
    required String cwd,
    required AgentRole role,
    String? title,
    String? model,
    String? effort,
  });
}

// ---- this app's backends ------------------------------------------------------

/// This app's worker types: Codex, Claude, and one Codex app-server per
/// custom type (`worker-types.json` in the state directory).
class LocalBody extends ChangeNotifier with Body {
  LocalBody({required this.name, required this.stateDir});

  @override
  String name;
  final String stateDir;

  late final CodexBackend codex;
  late final ClaudeBackend claude;

  /// Every worker type configured here.
  List<WorkerType> types = [WorkerType.codex, WorkerType.claude];

  /// The custom types' app-servers that started.
  final custom = <String, CodexBackend>{};

  /// Why a worker type cannot run (its app-server failed, a bad config);
  /// the others still work.
  final typeErrors = <String, String>{};
  String? startupError;
  bool ready = false;

  @override
  String projectDir =
      Platform.environment['ORCH_CWD'] ?? Platform.environment['HOME'] ?? '/';

  /// Runs orchestrator tool calls (set by the brain's hub; bodies have none).
  ToolHandler? toolHandler;

  /// Claude permission prompts that need the user (the orchestrator's
  /// AskUserQuestion).
  void Function()? onUserPrompt;

  final protocolLog = <ProtocolLogEntry>[];

  @override
  bool get online => true;

  @override
  bool get isLocal => true;

  Future<ToolResult> _onTool(AgentThread caller, String tool, Json args) =>
      toolHandler?.call(caller, tool, args) ??
      Future.value(
        ToolResult('error: no orchestrator tools on body $name', false),
      );

  @override
  Future<Json> readImage(String path) => loadImage(path);

  void _log(RpcClient c) => c.log.listen((e) {
    protocolLog.add(e);
    if (protocolLog.length > 3000) protocolLog.removeRange(0, 1000);
  });

  Future<void> start() async {
    try {
      codex = CodexBackend(await codexAppServer(), onTool: _onTool)
        ..onChanged = notifyListeners;
      claude = ClaudeBackend(claudeBridge(), onTool: _onTool)
        ..onChanged = notifyListeners
        ..onUserPrompt = (_, _) => onUserPrompt?.call();
      _log(codex.client);
      _log(claude.client);
      _loadTypes();
      await Future.wait([
        codex.start(),
        claude.start(projectDir),
        for (final t in types)
          if (t.kind == WorkerKind.custom) _startCustom(t),
      ]);
      ready = true;
    } catch (e) {
      startupError = '$e';
    }
    notifyListeners();
  }

  /// `worker-types.json` in the state directory (`ORCH_WORKER_TYPES`
  /// overrides the path).
  File get typesFile => File(
    Platform.environment['ORCH_WORKER_TYPES'] ?? '$stateDir/worker-types.json',
  );

  void _loadTypes() {
    try {
      types = WorkerType.load(typesFile, Platform.environment);
    } catch (e) {
      typeErrors['config'] = '${typesFile.path}: $e';
    }
  }

  Future<void> _startCustom(WorkerType t) async {
    try {
      final b = CodexBackend(
        await customAppServer(t, stateDir),
        onTool: _onTool,
        workerType: t.id,
      )..onChanged = notifyListeners;
      _log(b.client);
      await b.start();
      custom[t.id] = b;
    } catch (e) {
      typeErrors[t.id] = '$e';
    }
  }

  CodexBackend? _codexFor(WorkerType t) => switch (t.kind) {
    WorkerKind.codex => codex,
    WorkerKind.custom => custom[t.id],
    WorkerKind.claude => null,
  };

  WorkerType? _type(String id) => types.where((t) => t.id == id).firstOrNull;

  bool _available(WorkerType t) =>
      ready && (t.kind != WorkerKind.custom || custom.containsKey(t.id));

  @override
  List<String> get workerTypes => [
    for (final t in types)
      if (_available(t)) t.id,
  ];

  @override
  List<Json> modelsFor(String type) {
    final t = _type(type);
    if (t == null || !_available(t)) return const [];
    return t.kind == WorkerKind.claude ? claude.models : _codexFor(t)!.models;
  }

  @override
  String? defaultModel(String type) {
    final t = _type(type);
    if (t == null || !_available(t)) return null;
    return t.kind == WorkerKind.claude
        ? claude.defaultModel
        : _codexFor(t)!.defaultModel;
  }

  @override
  Json get info {
    final codexLimit = ready ? (codex.rateLimits?['primary'] as Map?) : null;
    final claudeLimit = ready ? claude.rateLimits : null;
    return {
      'name': name,
      'host': Platform.localHostname.split('.').first,
      'ready': ready,
      'startupError': startupError,
      'workerTypes': [
        for (final t in types)
          t.toInfo(
            error: _available(t)
                ? null
                : typeErrors[t.id] ?? startupError ?? (ready ? 'not started' : 'starting'),
          ),
      ],
      'typeConfigError': typeErrors['config'],
      'projectDir': projectDir,
      'models': {for (final id in workerTypes) id: modelsFor(id)},
      'defaultModels': {for (final id in workerTypes) id: defaultModel(id)},
      'usage': {
        if (ready) ...{
          'codex':
              'Codex · ${codex.account?['planType'] ?? '?'}'
              '${codexLimit != null ? ' · ${codexLimit['usedPercent']}% of week' : ''}',
          'claude':
              'Claude · ${claude.account?['subscriptionType'] ?? '?'}'
              '${claudeLimit != null ? ' · ${claudeLimit['rateLimitType'] ?? ''} ${claudeLimit['status']}' : ''}',
        },
      },
    };
  }

  @override
  AgentThread create(
    String type, {
    required String label,
    required String cwd,
    required AgentRole role,
    String? title,
    String? model,
    String? effort,
  }) {
    final t = _type(type);
    if (t == null) {
      throw StateError('no worker type "$type" on $name (have: ${workerTypes.join(', ')})');
    }
    if (!_available(t)) {
      throw StateError('worker type "$type" is not available on $name: ${typeErrors[type] ?? 'not started'}');
    }
    final codexLike = _codexFor(t);
    final AgentThread agent = codexLike != null
        ? codexLike.create(
            label: label,
            cwd: cwd,
            role: role,
            title: title,
            model: model,
            effort: effort,
          )
        : claude.create(
            label: label,
            cwd: cwd,
            role: role,
            title: title,
            model: model,
            effort: effort,
          );
    return agent..body = name;
  }

  void answer(Object requestId, Object? result) =>
      claude.client.respond(requestId, result);

  void closeBackends() {
    for (final b in custom.values) {
      b.client.dispose();
    }
    codex.client.dispose();
    claude.client.dispose();
  }
}

// ---- serving this app's backends to the brain ---------------------------------

/// Runs a brain's requests (`agent/create`, `start`, `send`, `interrupt`,
/// `close`, `file/image`) on this app's backends and streams each agent's
/// transcript operations back. One per brain this app is linked to; only the
/// brain that owns this body ([ownerOf]) is served.
class BodyHost {
  BodyHost(this.local, this.peer, {required this.ownerOf}) {
    peer.messages.listen(_onMessage);
    local.addListener(_scheduleInfo);
    peer.send({'t': 'hello', 'info': local.info});
    peer.closed.then((_) => _onClosed());
  }

  final LocalBody local;
  final Peer peer;

  /// The brain that owns this body now (the signaling server's record).
  final String? Function() ownerOf;
  final _agents = <String, AgentThread>{};
  final _sent = <String, int>{};
  Timer? _infoTimer;

  void _scheduleInfo() {
    _infoTimer ??= Timer(const Duration(milliseconds: 500), () {
      _infoTimer = null;
      peer.send({'t': 'info', 'info': local.info});
    });
  }

  void _onMessage(Json m) {
    if (m['t'] != 'rpc') return;
    final rid = m['rid'];
    final p = (m['p'] as Map? ?? const {}).cast<String, dynamic>();
    final owner = ownerOf();
    // Agents a brain already started may still be closed by it.
    final mine = owner == peer.name ||
        (m['m'] == 'agent/close' || m['m'] == 'agent/interrupt') &&
            _agents.containsKey(p['id']);
    if (!mine) {
      peer.send({
        't': 'res',
        'rid': rid,
        'e': 'body ${local.name} belongs to ${owner ?? 'no brain'}, not to ${peer.name}',
      });
      return;
    }
    // Synchronous so that a create is in place before the start behind it.
    if (m['m'] == 'agent/create') {
      try {
        _create(p);
        peer.send({'t': 'res', 'rid': rid, 'r': null});
      } catch (e) {
        peer.send({'t': 'res', 'rid': rid, 'e': '$e'});
      }
      return;
    }
    unawaited(() async {
      try {
        final r = await _call(m['m'] as String, p);
        peer.send({'t': 'res', 'rid': rid, 'r': r});
      } catch (e) {
        peer.send({'t': 'res', 'rid': rid, 'e': '$e'});
      }
    }());
  }

  void _create(Json p) {
    final id = p['id'] as String;
    final agent = local.create(
      p['workerType'] as String,
      label: id,
      cwd: p['cwd'] as String,
      role: const AgentRole.worker(),
      title: p['title'] as String?,
      model: p['model'] as String?,
      effort: p['effort'] as String?,
    );
    _agents[id] = agent;
    _sent[id] = 0;
    agent.view.addListener(() => _flush(id));
    agent.finished.listen((_) {
      _flush(id);
      peer.send({
        't': 'agent',
        'id': id,
        'ev': {'k': 'finished'},
      });
    });
  }

  void _flush(String id) {
    final ops = _agents[id]!.view.ops;
    final from = _sent[id]!;
    if (ops.length == from) return;
    _sent[id] = ops.length;
    peer.send({
      't': 'agent',
      'id': id,
      'ev': {'k': 'ops', 'from': from, 'ops': ops.sublist(from)},
    });
  }

  Future<Object?> _call(String method, Json p) async {
    if (method == 'file/image') return loadImage(p['path'] as String);
    final agent = _agents[p['id']];
    if (agent == null) throw StateError('no agent ${p['id']} on ${local.name}');
    switch (method) {
      case 'agent/start':
        await agent.start(p['text'] as String);
        return {'backendId': agent.backendId, 'model': agent.model};
      case 'agent/send':
        await agent.send(
          p['text'] as String,
          afterCurrentTurn: p['afterCurrentTurn'] == true,
        );
        return {'model': agent.model};
      case 'agent/interrupt':
        await agent.interrupt();
        return null;
      case 'agent/close':
        await agent.close();
        return null;
    }
    throw StateError('unknown method $method');
  }

  /// The brain went away: its workers here have no one to report to.
  Future<void> _onClosed() async {
    local.removeListener(_scheduleInfo);
    _infoTimer?.cancel();
    for (final a in _agents.values) {
      if (a.view.isRunning) await a.interrupt();
    }
  }
}

// ---- another app's backends, seen from the brain ------------------------------

/// A body app connected to the brain.
class RemoteBody with Body {
  RemoteBody(this.peer, this.info) : name = peer.name {
    peer.messages.listen(_onMessage);
  }

  final Peer peer;
  @override
  final String name;
  @override
  Json info;
  @override
  bool online = true;

  @override
  bool get isLocal => false;

  void Function()? onChanged;

  /// The body introduced itself (its first message).
  void Function()? onHello;

  final _agents = <String, RemoteAgent>{};
  final _pending = <int, Completer<Object?>>{};
  int _rid = 0;

  Future<Object?> rpc(String method, Json params) {
    if (!online) return Future.error(StateError('body $name is offline'));
    final rid = ++_rid;
    final c = Completer<Object?>();
    _pending[rid] = c;
    peer.send({'t': 'rpc', 'rid': rid, 'm': method, 'p': params});
    return c.future;
  }

  void _onMessage(Json m) {
    switch (m['t']) {
      case 'res':
        final c = _pending.remove(m['rid']);
        if (c == null) return;
        if (m['e'] != null) {
          c.completeError(StateError(m['e'] as String));
        } else {
          c.complete(m['r']);
        }
      case 'agent':
        _agents[m['id']]?._onEvent((m['ev'] as Map).cast<String, dynamic>());
      case 'hello':
        info = (m['info'] as Map).cast<String, dynamic>();
        onHello?.call();
      case 'info':
        info = (m['info'] as Map).cast<String, dynamic>();
        onChanged?.call();
    }
  }

  /// The link closed: fail what was waiting and what was running.
  void lost() {
    online = false;
    for (final c in _pending.values) {
      c.completeError(StateError('body $name disconnected'));
    }
    _pending.clear();
    for (final a in _agents.values) {
      a.markLost('body $name disconnected');
    }
  }

  @override
  Future<Json> readImage(String path) async =>
      ((await rpc('file/image', {'path': path})) as Map)
          .cast<String, dynamic>();

  @override
  AgentThread create(
    String type, {
    required String label,
    required String cwd,
    required AgentRole role,
    String? title,
    String? model,
    String? effort,
  }) {
    if (role.isOrchestrator) {
      throw StateError('the orchestrator runs on the brain');
    }
    final agent = RemoteAgent(
      this,
      label: label,
      workerType: type,
      cwd: cwd,
      title: title,
      model: model,
      effort: effort,
    )..body = name;
    _agents[label] = agent;
    unawaited(
      rpc('agent/create', {
        'id': label,
        'workerType': type,
        'cwd': cwd,
        'title': title,
        'model': model,
        'effort': effort,
      }).catchError((Object e) {
        agent.view.addError('$e');
        return null;
      }),
    );
    return agent;
  }
}

/// A worker on another app. Its transcript is rebuilt from the operations
/// the body streams; its state is kept here like a local worker's.
class RemoteAgent extends AgentThread {
  RemoteAgent(
    this.remote, {
    required super.label,
    required super.workerType,
    required super.cwd,
    super.title,
    super.model,
    super.effort,
  });

  final RemoteBody remote;

  void _onEvent(Json ev) {
    switch (ev['k']) {
      case 'ops':
        final from = (ev['from'] as num).toInt();
        final ops = (ev['ops'] as List).cast<Map>();
        for (var i = 0; i < ops.length; i++) {
          // Ordered channel: anything below our count was applied already.
          if (from + i < view.ops.length) continue;
          view.apply(ops[i].cast<String, dynamic>());
        }
      case 'finished':
        onTurnFinished();
    }
  }

  @override
  Future<void> start(String text) async {
    final r =
        await remote.rpc('agent/start', {'id': label, 'text': text}) as Map?;
    view.threadId = r?['backendId'] as String? ?? label;
    model = r?['model'] as String? ?? model;
    notifyListeners();
  }

  @override
  Future<void> send(String text, {bool afterCurrentTurn = false}) async {
    await remote.rpc('agent/send', {
      'id': label,
      'text': text,
      'afterCurrentTurn': afterCurrentTurn,
    });
  }

  @override
  Future<void> interrupt() async {
    await remote.rpc('agent/interrupt', {'id': label});
  }

  @override
  Future<void> close() async {
    if (!remote.online) return;
    await remote.rpc('agent/close', {'id': label});
  }
}

// ---- images -------------------------------------------------------------------

const _imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'heic',
  'webp',
  'tif',
  'tiff',
  'bmp',
};

/// Reads an image file and returns it as JPEG (`{mime, data (base64), bytes,
/// width, height, path}`), its long side scaled down to [maxSide]. Only
/// image files: the brain can ask any body for one, and the link has no
/// authentication. Uses macOS's `sips`.
Future<Json> loadImage(String path, {int maxSide = 1600}) async {
  final ext = path.split('.').last.toLowerCase();
  if (!_imageExtensions.contains(ext)) {
    throw StateError('not an image file: $path');
  }
  final file = File(path);
  if (!await file.exists()) throw StateError('no such file: $path');
  if (await file.length() > 50 * 1024 * 1024) {
    throw StateError('too large (over 50 MB): $path');
  }
  final tmp = await Directory.systemTemp.createTemp('orch-image');
  try {
    final out = '${tmp.path}/image.jpg';
    final size = await Process.run('/usr/bin/sips', [
      '-g',
      'pixelWidth',
      '-g',
      'pixelHeight',
      path,
    ]);
    int? dim(String key) => int.tryParse(
      RegExp('$key: (\\d+)').firstMatch('${size.stdout}')?.group(1) ?? '',
    );
    final w = dim('pixelWidth'), h = dim('pixelHeight');
    final shrink = w != null && h != null && (w > maxSide || h > maxSide);
    final r = await Process.run('/usr/bin/sips', [
      '-s',
      'format',
      'jpeg',
      '-s',
      'formatOptions',
      '80',
      if (shrink) ...['-Z', '$maxSide'],
      path,
      '--out',
      out,
    ]);
    if (r.exitCode != 0) throw StateError('sips failed: ${r.stderr}');
    final bytes = await File(out).readAsBytes();
    if (bytes.length > 4 * 1024 * 1024) {
      throw StateError('still over 4 MB after scaling: $path');
    }
    final scaled = await Process.run('/usr/bin/sips', [
      '-g',
      'pixelWidth',
      '-g',
      'pixelHeight',
      out,
    ]);
    int? outDim(String key) => int.tryParse(
      RegExp('$key: (\\d+)').firstMatch('${scaled.stdout}')?.group(1) ?? '',
    );
    return {
      'mime': 'image/jpeg',
      'data': base64Encode(bytes),
      'bytes': bytes.length,
      'width': outDim('pixelWidth'),
      'height': outDim('pixelHeight'),
      'originalWidth': w,
      'originalHeight': h,
      'path': path,
    };
  } finally {
    await tmp.delete(recursive: true);
  }
}
