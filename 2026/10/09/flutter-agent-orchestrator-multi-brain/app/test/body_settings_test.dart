import 'dart:convert';

import 'package:agent_orchestrator/agents/agent_check.dart';
import 'package:agent_orchestrator/agents/worker_types.dart';
import 'package:agent_orchestrator/state/thread_view.dart' show Json;
import 'package:agent_orchestrator/ui/body_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The body's machine: Codex logged in with two models, Claude not.
class _BodyChecker extends AgentChecker {
  @override
  Future<CheckResult> codex(String? cwd) async => const CheckResult(
    true,
    'Logged in (pro)',
    models: [
      ModelInfo('gpt-big', null, label: 'GPT Big', isDefault: true),
      ModelInfo('gpt-small', null, label: 'GPT Small'),
    ],
  );

  @override
  Future<CheckResult> claude(String? cwd) async =>
      const CheckResult(false, 'Not logged in', needsLogin: true);

  @override
  Future<List<Requirement>> computerUse() async => const [
    Requirement('Computer Use plugin', false, 'Off', grant: 'accessibility'),
  ];
}

/// Opens the dialog the way the console's body list does.
/// Brains [open] passed `assign` (null: not called).
List<String>? assigned;

Future<void> open(
  WidgetTester tester, {
  BodyRequest? request,
  List<String> owners = const ['brain-a'],
}) async {
  assigned = null;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showBodySettings(
            context,
            body: 'body-c',
            owners: owners,
            brains: const ['brain-a', 'brain-b'],
            assign: (b) async {
              assigned = b;
              return (true, null);
            },
            request: request,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a body\'s agents: read there, checked there, saved there', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sent = <String, Json>{};
    // The body's side of `body/...`, through JSON as on the link.
    Future<Object?> request(String m, [Json p = const {}]) async {
      sent[m] = jsonDecode(jsonEncode(p)) as Json;
      final Object? r = switch (m) {
        'body/config' => {
          'config': WorkerTypesConfig(
            codex: BuiltinSetup(computerUse: true),
            maxWorkers: 2,
          ).toJson(),
          'projectDirDefault': '/Users/someone',
        },
        'body/check' when p['what'] == 'permissions' => {
          'screenRecording': true,
          'accessibility': false,
        },
        'body/check' => await runCheck(
          _BodyChecker(),
          p['what'] as String,
          (p['args'] as Map).cast(),
        ),
        'body/configure' => {},
        _ => throw StateError('unexpected $m'),
      };
      return jsonDecode(jsonEncode(r));
    }

    await open(tester, request: request);

    expect(find.text('Settings of body-c'), findsOneWidget);
    expect(find.textContaining('Empty: /Users/someone'), findsOneWidget);
    expect(find.text('✓ Logged in (pro)'), findsOneWidget);
    expect(find.text('✗ Not logged in'), findsOneWidget);
    // Logging in and granting stay on that machine.
    expect(find.byKey(const Key('codex-login')), findsNothing);
    expect(find.textContaining('Grant'), findsOneWidget); // the sentence only
    expect(find.text('✗ Computer Use plugin: Off'), findsOneWidget);
    expect(find.byKey(const Key('model-codex')), findsOneWidget);

    // Claude off, Codex on its smaller model, then save.
    await tester.tap(find.byKey(const Key('agent-claude')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('model-codex')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT Small').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body-settings-save')));
    await tester.pumpAndSettle();

    final config = WorkerTypesConfig.fromJson(
      (sent['body/configure']!['config'] as Map).cast(),
    );
    expect(config.claude.enabled, false);
    expect(config.codex.model, 'gpt-small');
    expect(config.codex.computerUse, true);
    expect(config.maxWorkers, 2);
    expect(
      find.text('Settings of body-c'),
      findsNothing,
      reason: 'closed after saving',
    );
  });

  testWidgets('a refusal from the body is shown and the dialog stays', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<Object?> request(String m, [Json p = const {}]) async => switch (m) {
      'body/config' => {'config': WorkerTypesConfig().toJson()},
      'body/configure' => throw StateError(
        '1 agent(s) still running on body-c',
      ),
      _ =>
        m == 'body/check' && p['what'] == 'permissions'
            ? null
            : (await runCheck(
                _BodyChecker(),
                p['what'] as String,
                (p['args'] as Map).cast(),
              )),
    };
    await open(tester, request: request);
    await tester.tap(find.byKey(const Key('agent-claude')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body-settings-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('still running on body-c'), findsOneWidget);
    expect(find.text('Settings of body-c'), findsOneWidget);
  });

  testWidgets(
    'its brains: shared with another brain; agents unchanged are not restarted',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final asked = <String>[];
      Future<Object?> request(String m, [Json p = const {}]) async {
        asked.add(m);
        return switch (m) {
          'body/config' => {'config': WorkerTypesConfig().toJson()},
          _ =>
            p['what'] == 'permissions'
                ? null
                : await runCheck(
                    _BodyChecker(),
                    p['what'] as String,
                    (p['args'] as Map).cast(),
                  ),
        };
      }

      await open(tester, request: request);
      expect(find.text('Belongs to'), findsOneWidget);
      await tester.tap(find.byKey(const Key('belongs-brain-b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('body-settings-save')));
      await tester.pumpAndSettle();
      expect(assigned, ['brain-a', 'brain-b']);
      expect(asked, isNot(contains('body/configure')));
      expect(find.text('Settings of body-c'), findsNothing);
    },
  );

  testWidgets('a body of no brain: only its brains, no relay needed', (
    tester,
  ) async {
    await open(tester, owners: const []);
    expect(find.textContaining('belongs to no brain yet'), findsOneWidget);
    expect(find.byKey(const Key('agent-codex')), findsNothing);
    await tester.tap(find.byKey(const Key('belongs-brain-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body-settings-save')));
    await tester.pumpAndSettle();
    expect(assigned, ['brain-a']);
  });
}
