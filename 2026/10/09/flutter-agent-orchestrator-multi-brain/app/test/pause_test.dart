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
    hub = Hub(LocalBody(name: 'brain', stateDir: '/nonexistent'))
      ..ownerOf = (_) => 'brain';
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

  test('the brain\'s own body: paused through the hub, reported in its info; the orchestrator is not a worker', () async {
    await hub.setPaused('brain', true);
    expect(hub.local.paused, true);
    expect(hub.local.info['paused'], true);
    expect(
      () => hub.local.create(
        'codex',
        label: 'w9',
        cwd: '/',
        role: const AgentRole.worker(),
      ),
      throwsA(predicate((e) => '$e'.contains('paused'))),
    );
    await hub.setPaused('brain', false);
    expect(hub.local.info['paused'], false);
  });
}
