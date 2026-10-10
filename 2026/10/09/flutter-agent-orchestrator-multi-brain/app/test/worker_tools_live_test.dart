// Which tools a worker's model is offered, with Computer Use on or off,
// through this app's own app-servers and a fake Responses API (no tokens).
// Needs Codex (and, for Computer Use, the Codex app's computer-use plugin).
// Opt-in: LIVE_CHECK=1 flutter test test/worker_tools_live_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_orchestrator/agents/backends.dart';
import 'package:agent_orchestrator/agents/worker_types.dart';
import 'package:agent_orchestrator/rpc/rpc_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request with "OK" and keeps the first request's body.
Future<(HttpServer, Completer<Map>)> fakeResponses() async {
  final first = Completer<Map>();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
    if (!first.isCompleted) first.complete(body);
    req.response.headers.contentType = ContentType('text', 'event-stream');
    final item = {'type': 'message', 'id': 'm1', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'OK'}]};
    final resp = {
      'id': 'r1', 'object': 'response', 'status': 'completed', 'output': [item],
      'usage': {'input_tokens': 1, 'input_tokens_details': {'cached_tokens': 0}, 'output_tokens': 1,
        'output_tokens_details': {'reasoning_tokens': 0}, 'total_tokens': 2},
    };
    for (final (ev, data) in [
      ('response.created', {'response': {...resp, 'status': 'in_progress', 'output': []}}),
      ('response.output_item.added', {'output_index': 0, 'item': item}),
      ('response.output_item.done', {'output_index': 0, 'item': item}),
      ('response.completed', {'response': resp}),
    ]) {
      req.response.write('event: $ev\ndata: ${jsonEncode({'type': ev, ...data})}\n\n');
    }
    await req.response.close();
  });
  return (server, first);
}

/// Tool names in a request, namespaces flattened (`mcp__cua_repl.js`).
List<String> toolNames(Map req) {
  final tools = [...?(req['tools'] as List?)];
  for (final it in (req['input'] as List? ?? const []).cast<Map>()) {
    if (it['type'] == 'additional_tools') tools.addAll(it['tools'] as List);
  }
  List<String> walk(List ts, String pre) => [
    for (final t in ts.cast<Map>())
      ...(t['type'] == 'namespace' ? walk(t['tools'] as List, '$pre${t['name']}.') : ['$pre${t['name'] ?? t['type']}']),
  ];
  return walk(tools, '');
}

void main() {
  final live = Platform.environment['LIVE_CHECK'] == '1';
  setUpAll(() => HttpOverrides.global = null);

  Future<List<String>> workerTools(bool computerUse) async {
    final (server, first) = await fakeResponses();
    final tmp = Directory.systemTemp.createTempSync('cu');
    final t = WorkerType.customFromJson({
      'id': 'fake',
      'base_url': 'http://127.0.0.1:${server.port}/v1',
      'model': 'fake-model',
      'computer_use': computerUse,
    });
    final backend = CodexBackend(
      await customAppServer(t, tmp.path),
      onTool: (_, _, _) async => ToolResult('', true),
      workerType: t.id,
    )..workerConfig = computerUse ? customWorkerConfig() : null;
    try {
      await backend.start();
      final agent = backend.create(label: 'w1', cwd: tmp.path, role: const AgentRole.worker());
      await agent.start('hi');
      return toolNames(await first.future.timeout(const Duration(seconds: 60)));
    } finally {
      backend.client.dispose();
      await server.close(force: true);
      tmp.deleteSync(recursive: true);
    }
  }

  test('custom, Computer Use off: no cua_repl, nothing from ~/.codex', () async {
    final names = await workerTools(false);
    // ignore: avoid_print
    print('off: $names');
    expect(names.where((n) => n.contains('cua_repl')), isEmpty);
    expect(names, contains('exec_command'));
  }, skip: !live, timeout: const Timeout(Duration(seconds: 90)));

  test('custom, Computer Use on: cua_repl, and the user\'s MCP servers stay off', () async {
    final names = await workerTools(true);
    // ignore: avoid_print
    print('on: $names');
    expect(names, contains('mcp__cua_repl.js'));
    for (final server in userMcpServers()) {
      expect(names.where((n) => n.startsWith('mcp__$server.')), isEmpty, reason: server);
    }
    expect(names.where((n) => n.startsWith('mcp__codex_apps')), isEmpty);
  }, skip: !live, timeout: const Timeout(Duration(seconds: 90)));
}
