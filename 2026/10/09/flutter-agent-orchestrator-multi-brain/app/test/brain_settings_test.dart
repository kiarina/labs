import 'dart:convert';
import 'dart:io';

import 'package:agent_orchestrator/agents/agent_check.dart';
import 'package:agent_orchestrator/agents/worker_types.dart';
import 'package:agent_orchestrator/orchestrator/brain_config.dart';
import 'package:agent_orchestrator/orchestrator/hub.dart';
import 'package:agent_orchestrator/state/thread_view.dart' show Json;
import 'package:agent_orchestrator/ui/brain_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The brain's machine: Codex with two models, Claude logged in.
class _BrainChecker extends AgentChecker {
  @override
  Future<CheckResult> codex(String? cwd) async => const CheckResult(
    true,
    'Logged in (pro)',
    models: [
      ModelInfo(
        'gpt-big',
        null,
        label: 'GPT Big',
        isDefault: true,
        efforts: ['low', 'high'],
      ),
      ModelInfo(
        'gpt-small',
        null,
        label: 'GPT Small',
        efforts: ['low', 'medium'],
      ),
    ],
  );

  @override
  Future<CheckResult> claude(String? cwd) async => const CheckResult(
    true,
    'Logged in (max)',
    models: [ModelInfo('opus', null, label: 'Opus')],
  );
}

void main() {
  test('brain.json: round trip, and ORCH_ORCHESTRATOR picks the agent', () {
    final dir = Directory.systemTemp.createTempSync('brain');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(BrainConfig.load(dir.path, const {}).kind, WorkerKind.codex);
    BrainConfig(
      kind: WorkerKind.custom,
      model: 'qwen',
      baseUrl: 'http://127.0.0.1:9/v1',
      envKey: 'KEY',
      wakeOnFinish: false,
    ).save(dir.path);
    final c = BrainConfig.load(dir.path, const {});
    expect(c.toJson(), {
      'kind': 'custom',
      'model': 'qwen',
      'wake_on_finish': false,
      'base_url': 'http://127.0.0.1:9/v1',
      'env_key': 'KEY',
    });
    expect(c.problem, isNull);
    expect(
      BrainConfig(kind: WorkerKind.custom).problem,
      contains('needs base_url and model'),
    );
    final claude = BrainConfig.load(dir.path, const {
      'ORCH_ORCHESTRATOR': 'claude',
    });
    expect((claude.kind, claude.model), (WorkerKind.claude, null));
  });

  test(
    'the hub answers brain requests; incomplete settings are refused',
    () async {
      final dir = Directory.systemTemp.createTempSync('hub');
      addTearDown(() => dir.deleteSync(recursive: true));
      final hub = Hub(name: 'brain-a', stateDir: dir.path);
      final r = await hub.request({'a': 'brain', 'm': 'brain/config'}) as Map;
      expect((r['config'] as Map)['kind'], 'codex');
      await expectLater(
        hub.request({
          'a': 'brain',
          'm': 'brain/configure',
          'p': {
            'config': {'kind': 'custom'},
          },
        }),
        throwsA(predicate((e) => '$e'.contains('needs base_url and model'))),
      );
      expect(File('${dir.path}/brain.json').existsSync(), false);
    },
  );

  testWidgets(
    'a brain\'s settings from a console: read there, checked there, saved there',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sent = <String, Json>{};
      Future<Object?> request(String m, [Json p = const {}]) async {
        sent[m] = jsonDecode(jsonEncode(p)) as Json;
        final Object? r = switch (m) {
          'brain/config' => {
            'config': BrainConfig(
              kind: WorkerKind.claude,
              cwd: '~/src',
            ).toJson(),
            'projectDirDefault': '/Users/someone/work',
          },
          'brain/check' => await runCheck(
            _BrainChecker(),
            p['what'] as String,
            (p['args'] as Map).cast(),
          ),
          'brain/configure' => null,
          _ => throw StateError('unexpected $m'),
        };
        return jsonDecode(jsonEncode(r));
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showBrainSettings(
                context,
                brain: 'brain-a',
                request: request,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Settings of brain-a'), findsOneWidget);
      expect(find.text('✓ Logged in (max)'), findsOneWidget);
      expect(find.textContaining('/Users/someone/work'), findsOneWidget);

      // Codex, its smaller model at medium effort.
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();
      expect(find.text('✓ Logged in (pro)'), findsOneWidget);
      await tester.tap(find.text('Default (GPT Big)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GPT Small').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('medium').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('brain-settings-save')));
      await tester.pumpAndSettle();

      expect(sent['brain/configure'], {
        'config': {
          'kind': 'codex',
          'model': 'gpt-small',
          'effort': 'medium',
          'cwd': '~/src',
          'wake_on_finish': true,
        },
      });
      expect(find.text('Settings of brain-a'), findsNothing);
    },
  );
}
