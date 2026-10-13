import 'dart:io';

import 'package:agent_orchestrator/agents/agent_thread.dart';
import 'package:agent_orchestrator/agents/backends.dart' show AgentRole;
import 'package:agent_orchestrator/orchestrator/brain_config.dart';
import 'package:agent_orchestrator/orchestrator/hub.dart';
import 'package:flutter_test/flutter_test.dart';

/// A conversation that records what it is sent and runs until [finish].
class _FakeThread extends AgentThread {
  _FakeThread(String label, this.role)
    : super(label: label, workerType: 'fake', cwd: '/');

  final AgentRole role;
  final sent = <(String, bool)>[];
  String answer = '';

  @override
  String get lastAnswer => answer;

  @override
  Future<void> start(String text) async {
    view.threadId = 'x-$label';
    sent.add((text, false));
    markRunning();
  }

  @override
  Future<void> send(String text, {bool afterCurrentTurn = false}) async {
    sent.add((text, afterCurrentTurn));
    if (!isRunning) markRunning();
  }

  void finish(String a) {
    answer = a;
    onTurnFinished();
  }

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> close() async {}
}

void main() {
  late Hub hub;
  final made = <String, _FakeThread>{};

  setUp(() {
    made.clear();
    final dir = Directory.systemTemp.createTempSync('dual');
    addTearDown(() => dir.deleteSync(recursive: true));
    hub = Hub(name: 'brain-a', stateDir: dir.path);
    hub.brain
      ..config = BrainConfig(mode: BrainMode.dual, talker: BrainConfig())
      ..fake = (label, role) => made[label] = _FakeThread(label, role);
    hub.talkerAgent.fake = (label, role) =>
        made[label] = _FakeThread(label, role);
  });

  test('the user talks to the talker; it has only the talker tools', () async {
    await hub.sendToOrchestrator('hi');
    final talker = made['talker']!;
    expect(hub.orchestrator, same(talker));
    expect(talker.sent.single.$1, 'hi');
    expect(
      [for (final t in talker.role.tools) t['name']],
      ['ask_thinker', 'thinker_status'],
    );
    expect(hub.thinker, isNull, reason: 'nothing to decide yet');
  });

  test('the thinker works on one request at a time; its result goes back to the talker', () async {
    await hub.sendToOrchestrator('run the tests on body-c, then lint');
    final talker = made['talker']!;

    expect(
      (await hub.askThinker('Run the tests on body-c'))['status'],
      'started',
    );
    final thinker = made['thinker']!;
    expect(hub.thinker, same(thinker));
    expect(
      thinker.sent.single.$1,
      '[request from the talker]\nRun the tests on body-c',
    );
    expect(thinker.role.instructions, contains('You are the thinker'));
    expect([
      for (final t in thinker.role.tools) t['name'],
    ], contains('start_thread'));

    // Busy: queued after, or added to the current work.
    final queued = await hub.askThinker('Then lint body-c');
    expect((queued['status'], queued['position']), ('queued', 1));
    expect(
      (await hub.askThinker('Use the fast suite', add: true))['status'],
      'added to its current work',
    );
    expect(thinker.sent.last.$1, contains('Use the fast suite'));

    final status = hub.thinkerStatus();
    expect(status['busy'], true);
    expect(status['working_on'], 'Run the tests on body-c');
    expect(status['waiting_requests'], ['Then lint body-c']);

    // Done: the talker hears it (after its own turn, since it is talking),
    // and the next request starts.
    thinker.finish('All 42 tests pass on body-c.');
    await Future<void>.delayed(Duration.zero);
    final (relayed, afterTurn) = talker.sent.last;
    expect(
      relayed,
      '[thinker result for: Run the tests on body-c]\nAll 42 tests pass on body-c.',
    );
    expect(afterTurn, true);
    expect(thinker.sent.last.$1, contains('Then lint body-c'));
    expect(hub.thinkerStatus()['working_on'], 'Then lint body-c');

    // A new conversation drops both, and what waited.
    await hub.newConversation();
    expect((hub.orchestrator, hub.thinker), (null, null));
    expect(hub.thinkerStatus()['busy'], false);
  });

  test('single mode: the orchestrator talks and acts', () async {
    hub.brain.config = BrainConfig();
    await hub.sendToOrchestrator('hi');
    expect(hub.orchestrator, same(made['orchestrator']));
    expect([
      for (final t in made['orchestrator']!.role.tools) t['name'],
    ], contains('start_thread'));
  });

  test('brain.json: the mode and the talker round-trip; a dual brain needs a usable talker', () {
    final c = BrainConfig(
      mode: BrainMode.dual,
      talker: BrainConfig(
        kind: WorkerKind.claude,
        model: 'sonnet',
        cwd: '/ignored',
      ),
      cwd: '~/src',
    );
    final j = c.toJson();
    expect(j['mode'], 'dual');
    expect(j['talker'], {'kind': 'claude', 'model': 'sonnet'});
    final back = BrainConfig.fromJson(j);
    expect(
      (back.mode, back.talker!.kind, back.talker!.model),
      (BrainMode.dual, WorkerKind.claude, 'sonnet'),
    );
    expect(
      BrainConfig(mode: BrainMode.dual).problem,
      'the talker has no agent',
    );
    expect(
      BrainConfig(
        mode: BrainMode.dual,
        talker: BrainConfig(kind: WorkerKind.custom),
      ).problem,
      contains('needs base_url and model'),
    );
    expect(BrainConfig().toJson().containsKey('mode'), false);
  });
}
