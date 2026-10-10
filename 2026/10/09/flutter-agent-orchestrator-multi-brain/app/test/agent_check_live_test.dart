// The real checks against this machine's Codex, Claude and a fake custom
// server. Starts agent processes but spends no model tokens. Opt-in:
//   LIVE_CHECK=1 CLAUDE_FLUTTER_SIDECAR=$PWD/../sidecar flutter test test/agent_check_live_test.dart
import 'dart:io';

import 'package:agent_orchestrator/agents/agent_check.dart';
import 'package:agent_orchestrator/agents/worker_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final live = Platform.environment['LIVE_CHECK'] == '1';
  setUpAll(() => HttpOverrides.global = null);
  const checker = AgentChecker();

  test('codex', () async {
    final r = await checker.codex('~');
    printOnFailure(r.text);
    // ignore: avoid_print
    print('codex: ${r.ok} ${r.text}');
    expect(r.ok || r.needsLogin, isTrue);
  }, skip: !live, timeout: const Timeout(Duration(seconds: 60)));

  test('claude', () async {
    final r = await checker.claude('~');
    // ignore: avoid_print
    print('claude: ${r.ok} ${r.text}');
    expect(r.text, isNotEmpty);
  }, skip: !live, timeout: const Timeout(Duration(seconds: 90)));

  test('a missing folder', () async {
    final r = await checker.codex('/no/such/folder');
    expect((r.ok, r.text), (false, 'No folder /no/such/folder'));
  }, skip: !live);

  test('custom: models listed, model missing, unreachable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response
        ..headers.contentType = ContentType.json
        ..write('{"object":"list","data":[{"id":"qwen"},{"id":"other"}]}')
        ..close();
    });
    WorkerType t(String model, String base) => WorkerType.customFromJson({'id': 'x', 'base_url': base, 'model': model});
    final base = 'http://127.0.0.1:${server.port}/v1';
    expect((await checker.custom(t('qwen', base))).text, 'Reachable, has qwen');
    expect((await checker.custom(t('nope', base))).ok, isFalse);
    await server.close(force: true);
    expect((await checker.custom(t('qwen', base))).text, startsWith('Cannot reach'));
  }, skip: !live);
}
