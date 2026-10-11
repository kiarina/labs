import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_orchestrator/agents/agent_thread.dart';
import 'package:agent_orchestrator/agents/backends.dart' show AgentRole;
import 'package:agent_orchestrator/body/body.dart';
import 'package:agent_orchestrator/orchestrator/hub.dart';
import 'package:agent_orchestrator/state/thread_view.dart' show Json;
import 'package:flutter_test/flutter_test.dart';
import 'package:orchestrator_signal/signal_server.dart' show SignalServer;

class _FakeAgent extends AgentThread {
  _FakeAgent({
    required super.label,
    required super.workerType,
    required super.cwd,
  });

  @override
  Future<void> start(String text) async => view.threadId = 'x-$label';

  @override
  Future<void> send(String text, {bool afterCurrentTurn = false}) async {
    if (!isRunning) markRunning();
  }

  void finish() => onTurnFinished();

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> close() async {}
}

/// A body shared by brain-a (this hub) and brain-b, as the hub sees it.
class _SharedBody with Body {
  @override
  String get name => 'body-c';
  @override
  bool get online => true;
  @override
  bool get isLocal => false;
  @override
  Json info = {
    'maxWorkers': 1,
    'workerTypes': [
      {'id': 'codex', 'kind': 'codex', 'label': 'Codex'},
    ],
  };

  /// What the body reports when [brain] uses it (null: free).
  void usedBy(String? brain) => info = {
    ...info,
    'heldBy': brain,
    'activity': [
      if (brain != null && brain != 'brain-a')
        {
          'brain': brain,
          'thread': 'w7',
          'workerType': 'codex',
          'title': 'build it',
          'state': 'running',
        },
    ],
  };

  @override
  Future<Json> readImage(String path) async => {};

  @override
  Future<Object?> call(String method, Json params) async => null;

  @override
  AgentThread create(
    String type, {
    required String label,
    required String cwd,
    required AgentRole role,
    String? title,
    String? model,
    String? effort,
  }) => _FakeAgent(label: label, workerType: type, cwd: cwd)..body = name;
}

/// A WebSocket app on the signaling server, as the real apps join.
class _App {
  _App(this.ws) {
    ws.listen((m) => _in.add((jsonDecode(m as String) as Map).cast()));
  }

  final WebSocket ws;
  final _in = StreamController<Json>.broadcast();

  static Future<_App> join(
    int port,
    String name, {
    bool brain = false,
    bool body = true,
  }) async {
    final app = _App(await WebSocket.connect('ws://127.0.0.1:$port'));
    app.send({'t': 'hello', 'name': name, 'brain': brain, 'body': body});
    await app.next('welcome');
    return app;
  }

  void send(Json m) => ws.add(jsonEncode(m));
  Future<Json> next(String t) => _in.stream.firstWhere((m) => m['t'] == t);
}

void main() {
  late Hub hub;
  late _SharedBody body;

  setUp(() {
    hub = Hub(name: 'brain-a', stateDir: '/nonexistent')
      ..ownersOf = (b) =>
          b == 'body-c' ? const ['brain-a', 'brain-b'] : const [];
    body = _SharedBody();
    hub.bodies[body.name] = body;
  });

  Future<Json> start(String prompt) => hub.callTool('start_thread', {
    'body': 'body-c',
    'worker_type': 'codex',
    'prompt': prompt,
  });

  test('a shared body in use by another brain: read only, its work listed, free again later', () async {
    await hub.callTool('list_bodies', {});
    body.usedBy('brain-b');
    final b = ((await hub.callTool('list_bodies', {}))['bodies'] as List)
        .cast<Map>()
        .single;
    expect(b['shared_with'], ['brain-b']);
    expect(b['in_use_by'], 'brain-b');
    expect((b['their_work'] as List).single, containsPair('title', 'build it'));
    expect((await start('one'))['error'], contains('in use by brain-b'));
    expect(hub.workers, isEmpty);

    body.usedBy(null);
    expect(hub.bodiesChanged(), contains('body-c is free again'));
    expect((await start('one'))['status'], 'running');
    body.usedBy('brain-a'); // the body now reports this brain using it
    expect(
      (await start('two'))['status'],
      'queued',
      reason: 'its own limit, not a refusal',
    );

    // brain-a finished and let go; brain-b took it before the queue moved.
    final w1 = hub.worker('w1')! as _FakeAgent;
    body.usedBy('brain-b');
    w1.finish();
    await Future<void>.delayed(Duration.zero);
    expect(hub.worker('w2')!.state, AgentState.queued);
    final threads =
        ((await hub.callTool('list_threads', {}))['threads'] as List)
            .cast<Map>();
    expect(threads[1]['waiting_for'], 'brain-b to finish on body-c');
    expect(
      (await hub.callTool('send_message', {
        'thread_id': 'w1',
        'message': 'more',
      }))['error'],
      contains('in use by brain-b'),
    );
    expect(hub.bodiesChanged(), contains('body-c is now in use by brain-b'));

    body.usedBy(null);
    hub.drainQueue();
    await Future<void>.delayed(Duration.zero);
    expect(hub.worker('w2')!.state, AgentState.running);
  });

  test('signaling: a body belongs to several brains; removing a busy one is refused', () async {
    late int port;
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
    final server = SignalServer(port: port, log: (_) {});
    await server.start();
    addTearDown(server.close);
    final a = await _App.join(port, 'brain-a', brain: true, body: false);
    final b = await _App.join(port, 'brain-b', brain: true, body: false);
    final c = await _App.join(port, 'body-c');

    c.send({
      't': 'assign',
      'id': 1,
      'body': 'body-c',
      'brains': ['brain-a', 'brain-b'],
    });
    expect((await c.next('assignResult'))['ok'], true);
    expect(server.owners['body-c'], ['brain-a', 'brain-b']);

    // brain-a has workers there: it refuses to be removed.
    final asked = a.next('releaseRequest');
    c.send({
      't': 'assign',
      'id': 2,
      'body': 'body-c',
      'brains': ['brain-b'],
    });
    final r = await asked;
    expect(r['body'], 'body-c');
    a.send({
      't': 'releaseReply',
      'id': r['id'],
      'ok': false,
      'reason': '1 worker of brain-a running',
    });
    final refused = await c.next('assignResult');
    expect(
      (refused['ok'], refused['reason']),
      (false, '1 worker of brain-a running'),
    );
    expect(server.owners['body-c'], ['brain-a', 'brain-b']);

    // Adding needs no one; a removed brain that agrees lets it go.
    final asked2 = b.next('releaseRequest');
    c.send({
      't': 'assign',
      'id': 3,
      'body': 'body-c',
      'brains': ['brain-a'],
    });
    final r2 = await asked2;
    b.send({'t': 'releaseReply', 'id': r2['id'], 'ok': true});
    expect((await c.next('assignResult'))['ok'], true);
    expect(server.owners['body-c'], ['brain-a']);
    for (final x in [a, b, c]) {
      await x.ws.close();
    }
  });
}
