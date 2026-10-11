import 'package:flutter_test/flutter_test.dart';
import 'package:agent_orchestrator/agents/agent_thread.dart';
import 'package:agent_orchestrator/agents/backends.dart' show AgentRole;
import 'package:agent_orchestrator/body/body.dart';
import 'package:agent_orchestrator/orchestrator/hub.dart';
import 'package:agent_orchestrator/state/thread_view.dart' show Json;

/// A worker that does nothing: it runs until [finish].
class _FakeAgent extends AgentThread {
  _FakeAgent({
    required super.label,
    required super.workerType,
    required super.cwd,
  });

  final sent = <String>[];

  @override
  Future<void> start(String text) async {
    view.threadId = 'x-$label';
    sent.add(text);
  }

  @override
  Future<void> send(String text, {bool afterCurrentTurn = false}) async {
    if (!isRunning) markRunning();
    sent.add(text);
  }

  void finish() => onTurnFinished();

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> close() async {}
}

/// A connected body as the brain sees it: what it reported ([info]).
class _FakeBody with Body {
  _FakeBody(this.name);

  @override
  final String name;
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

  void report({required bool paused}) => info = {...info, 'paused': paused};

  @override
  Future<Json> readImage(String path) async => {};

  /// What a console asked of it.
  final calls = <String>[];

  @override
  Future<Object?> call(String method, Json params) async {
    calls.add(method);
    switch (method) {
      case 'body/pause':
        report(paused: params['paused'] == true);
      case 'body/configure':
        info = {
          ...info,
          'maxWorkers': (params['config'] as Map)['max_workers'],
        };
    }
    return null;
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
  }) => _FakeAgent(label: label, workerType: type, cwd: cwd)..body = name;
}

void main() {
  late Hub hub;
  late _FakeBody body;

  setUp(() {
    hub = Hub(name: 'brain', stateDir: '/nonexistent')
      ..ownersOf = (_) => const ['brain'];
    body = _FakeBody('body-c');
    hub.bodies[body.name] = body;
  });

  Future<Json> start(String prompt) => hub.callTool('start_thread', {
    'body': 'body-c',
    'worker_type': 'codex',
    'prompt': prompt,
  });

  test('paused: nothing new starts; running and queued ones are kept; resumed: the queue moves', () async {
    expect((await start('one'))['status'], 'running');
    expect((await start('two'))['status'], 'queued'); // one at a time
    final w1 = hub.worker('w1')! as _FakeAgent;
    final w2 = hub.worker('w2')! as _FakeAgent;
    await hub.callTool('list_bodies', {});

    body.report(paused: true);
    expect(hub.bodiesChanged(), contains('body-c is paused by the user'));
    final bodies = (await hub.callTool('list_bodies', {}))['bodies'] as List;
    expect(
      (bodies.cast<Map>().firstWhere((b) => b['body'] == 'body-c'))['paused'],
      true,
    );

    // New work is refused before it reaches the body.
    final refused = await start('three');
    expect(refused['error'], contains('paused'));
    expect(hub.workers.length, 2);

    // The running turn can still be steered, and finishes.
    expect(
      (await hub.callTool('send_message', {
        'thread_id': 'w1',
        'message': 'also',
      }))['status'],
      'steered',
    );
    w1.finish();
    await Future<void>.delayed(Duration.zero);
    expect(
      w2.state,
      AgentState.queued,
      reason: 'the slot is free, but the body is paused',
    );
    final threads = (await hub.callTool('list_threads', {}))['threads'] as List;
    expect((threads[1] as Map)['waiting_for'], contains('resumed'));

    // A new turn for a finished thread is new work.
    expect(
      (await hub.callTool('send_message', {
        'thread_id': 'w1',
        'message': 'more',
      }))['error'],
      contains('paused'),
    );

    body.report(paused: false);
    hub.drainQueue();
    await Future<void>.delayed(Duration.zero);
    expect(w2.state, AgentState.running);
    expect(w2.sent, ['two']);
    expect(hub.bodiesChanged(), contains('body-c is resumed'));
  });

  test('an app\'s body: paused by a request, reported in its info, takes no new worker', () async {
    final local = LocalBody(name: 'body-a', stateDir: '/nonexistent');
    await local.call('body/pause', {'paused': true});
    expect(local.paused, true);
    expect(local.info['paused'], true);
    expect(
      () => local.create(
        'codex',
        label: 'w9',
        cwd: '/',
        role: const AgentRole.worker(),
      ),
      throwsA(predicate((e) => '$e'.contains('paused'))),
    );
    await local.call('body/pause', {'paused': false});
    expect(local.info['paused'], false);
  });

  test('new settings only while paused with nothing of this brain there; its threads end', () async {
    Future<Object?> configure() => hub.bodyRequest('body-c', 'body/configure', {
      'config': {'max_workers': 3},
    });
    await start('one');
    final w1 = hub.worker('w1')! as _FakeAgent;

    await expectLater(
      configure(),
      throwsA(predicate((e) => '$e'.contains('pause body-c'))),
    );
    await hub.bodyRequest('body-c', 'body/pause', {'paused': true});
    expect(body.paused, true);
    await expectLater(
      configure(),
      throwsA(predicate((e) => '$e'.contains('running or queued'))),
    );

    w1.finish();
    await configure();
    expect(body.calls, ['body/pause', 'body/configure']);
    expect(body.maxWorkers, 3);

    // Its thread is gone with the old agents.
    final r = await hub.callTool('send_message', {
      'thread_id': 'w1',
      'message': 'again',
    });
    expect(r['error'], contains('restarted with new settings'));
    final t =
        ((await hub.callTool('list_threads', {}))['threads'] as List).single
            as Map;
    expect(t['ended'], isNotNull);

    // Only body requests go through.
    await expectLater(
      hub.bodyRequest('body-c', 'agent/start', {}),
      throwsA(predicate((e) => '$e'.contains('not a body request'))),
    );
  });

  test('an app\'s body: settings refused unless paused', () async {
    await expectLater(
      LocalBody(
        name: 'body-a',
        stateDir: '/nonexistent',
      ).reconfigure(WorkerTypesConfig()),
      throwsA(predicate((e) => '$e'.contains('pause body-a'))),
    );
  });
}
