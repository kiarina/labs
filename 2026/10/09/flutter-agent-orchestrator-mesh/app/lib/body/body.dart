import 'dart:async';
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

  /// What the body reports about itself: host, providers, project
  /// directory, models, subscription usage.
  Json get info;

  List<Provider> get providers =>
      [for (final p in (info['providers'] as List? ?? const [])) Provider.parse(p as String)];

  String get projectDir => info['projectDir'] as String? ?? '/';

  List<Json> modelsFor(Provider p) =>
      ((info['models'] as Map?)?[p.name] as List? ?? const [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();

  String? defaultModel(Provider p) =>
      (info['defaultModels'] as Map?)?[p.name] as String?;

  /// A new agent on this body; it starts when [AgentThread.start] is called.
  AgentThread create(
    Provider p, {
    required String label,
    required String cwd,
    required AgentRole role,
    String? title,
    String? model,
    String? effort,
  });
}

// ---- this app's backends ------------------------------------------------------

/// The Codex, Claude and kiapi backends of this app.
class LocalBody extends ChangeNotifier with Body {
  LocalBody({required this.name, required this.stateDir});

  @override
  String name;
  final String stateDir;

  late final CodexBackend codex;
  late final ClaudeBackend claude;

  /// A second Codex app-server whose model provider is kiapi. Null when it
  /// failed to start ([kiapiError]); the other providers still work.
  CodexBackend? kiapi;
  String? kiapiError;
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

  Future<(String, bool)> _onTool(AgentThread caller, String tool, Json args) =>
      toolHandler?.call(caller, tool, args) ??
      Future.value(('error: no orchestrator tools on body $name', false));

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
      await Future.wait([
        codex.start(),
        claude.start(projectDir),
        _startKiapi(),
      ]);
      ready = true;
    } catch (e) {
      startupError = '$e';
    }
    notifyListeners();
  }

  Future<void> _startKiapi() async {
    try {
      final k = CodexBackend(
        await kiapiAppServer(stateDir),
        onTool: _onTool,
        provider: Provider.kiapi,
      )..onChanged = notifyListeners;
      _log(k.client);
      await k.start();
      kiapi = k;
    } catch (e) {
      kiapiError = '$e';
    }
  }

  @override
  List<Provider> get providers => [
    if (ready) ...[Provider.codex, Provider.claude],
    if (kiapi != null) Provider.kiapi,
  ];

  @override
  List<Json> modelsFor(Provider p) => !ready
      ? const []
      : switch (p) {
          Provider.codex => codex.models,
          Provider.claude => claude.models,
          Provider.kiapi => kiapi?.models ?? const [],
        };

  @override
  String? defaultModel(Provider p) => !ready
      ? null
      : switch (p) {
          Provider.codex => codex.defaultModel,
          Provider.claude => claude.defaultModel,
          Provider.kiapi => kiapi?.defaultModel,
        };

  @override
  Json get info {
    final codexLimit = ready ? (codex.rateLimits?['primary'] as Map?) : null;
    final claudeLimit = ready ? claude.rateLimits : null;
    return {
      'name': name,
      'host': Platform.localHostname.split('.').first,
      'ready': ready,
      'startupError': startupError,
      'providers': [for (final p in providers) p.name],
      'projectDir': projectDir,
      'models': {for (final p in providers) p.name: modelsFor(p)},
      'defaultModels': {for (final p in providers) p.name: defaultModel(p)},
      'kiapiError': kiapiError,
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
    Provider p, {
    required String label,
    required String cwd,
    required AgentRole role,
    String? title,
    String? model,
    String? effort,
  }) {
    final codexLike = switch (p) {
      Provider.codex => codex,
      Provider.kiapi => kiapi,
      Provider.claude => null,
    };
    if (p == Provider.kiapi && codexLike == null) {
      throw StateError('kiapi is not available on $name: $kiapiError');
    }
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
    kiapi?.client.dispose();
    codex.client.dispose();
    claude.client.dispose();
  }
}

// ---- serving this app's backends to the brain ---------------------------------

/// Runs the brain's requests (`agent/create`, `start`, `send`, `interrupt`,
/// `close`) on this app's backends and streams each agent's transcript
/// operations back.
class BodyHost {
  BodyHost(this.local, this.peer) {
    peer.messages.listen(_onMessage);
    local.addListener(_scheduleInfo);
    peer.send({'t': 'hello', 'info': local.info});
    peer.closed.then((_) => _onClosed());
  }

  final LocalBody local;
  final Peer peer;
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
      Provider.parse(p['provider'] as String),
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

  /// Console actions (`t: action`) sent from the body app's console.
  void Function(Json action)? onAction;
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
      case 'action':
        onAction?.call((m['a'] as Map).cast<String, dynamic>());
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
  AgentThread create(
    Provider p, {
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
      provider: p,
      cwd: cwd,
      title: title,
      model: model,
      effort: effort,
    )..body = name;
    _agents[label] = agent;
    unawaited(
      rpc('agent/create', {
        'id': label,
        'provider': p.name,
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
    required super.provider,
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
    final r = await remote.rpc('agent/start', {'id': label, 'text': text}) as Map?;
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
