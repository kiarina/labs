import 'dart:convert';
import 'dart:io';

import 'package:agent_orchestrator/agents/worker_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('types'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(Object j) =>
      File('${tmp.path}/worker-types.json')..writeAsStringSync(jsonEncode(j));

  List<String> ids(WorkerTypesConfig c) => [for (final t in c.types) t.id];

  test('no file: Codex and Claude; kiapi only when KIAPI_BASE_URL is set', () {
    final none = File('${tmp.path}/none.json');
    expect(ids(WorkerTypesConfig.load(none, const {})), ['codex', 'claude']);
    final k = WorkerTypesConfig.load(none, {'KIAPI_BASE_URL': 'http://k:1/'});
    expect(ids(k), ['codex', 'claude', 'kiapi']);
    expect(k.types.last.baseUrl, 'http://k:1/v1');
  });

  test('Codex off, Claude with a folder, a custom one; the key is sent by name only', () {
    final c = WorkerTypesConfig.load(
      write({
        'codex': {'enabled': false},
        'claude': {'enabled': true, 'cwd': '~/src'},
        'custom': [
          {
            'id': 'local-qwen',
            'base_url': 'http://127.0.0.1:11434/v1/',
            'model': 'qwen',
            'env_key': 'SECRET_KEY',
            'max_concurrent': 2,
            'description': 'small tasks',
          },
        ],
      }),
      const {},
    );
    expect(ids(c), ['claude', 'local-qwen']);
    expect(c.types.first.resolvedCwd, '${Platform.environment['HOME']}/src');
    final info = c.types.last.toInfo();
    expect(info, {
      'id': 'local-qwen',
      'kind': 'custom',
      'label': 'local-qwen',
      'description': 'small tasks',
      'maxConcurrent': 2,
      'model': 'qwen',
      'extras': <String>[],
    });
    expect(c.types.last.baseUrl, 'http://127.0.0.1:11434/v1');
    expect(jsonEncode(info).contains('SECRET'), isFalse);
  });

  test('none at all is allowed, and it round-trips', () {
    final c = WorkerTypesConfig(
      codex: BuiltinSetup(enabled: false),
      claude: BuiltinSetup(enabled: false),
    );
    expect(c.types, isEmpty);
    final f = File('${tmp.path}/w.json');
    c.save(f);
    expect(WorkerTypesConfig.load(f, const {}).types, isEmpty);
  });

  test('bad configs are refused', () {
    Object custom(List<Object> l) => {'custom': l};
    expect(() => WorkerTypesConfig.load(write(custom([{'id': 'codex', 'base_url': 'x', 'model': 'm'}])), const {}),
        throwsFormatException);
    expect(() => WorkerTypesConfig.load(write(custom([{'id': 'Bad Id', 'base_url': 'x', 'model': 'm'}])), const {}),
        throwsFormatException);
    expect(() => WorkerTypesConfig.load(write(custom([{'id': 'a'}])), const {}), throwsFormatException);
    expect(
      () => WorkerTypesConfig.load(
        write(custom([
          {'id': 'a', 'base_url': 'x', 'model': 'm'},
          {'id': 'a', 'base_url': 'y', 'model': 'n'},
        ])),
        const {},
      ),
      throwsFormatException,
    );
  });

  test('tools that drive the Mac or Chrome: off unless turned on, and round-trip', () {
    final c = WorkerTypesConfig.load(
      write({
        'codex': {'enabled': true, 'computer_use': true},
        'claude': {'enabled': true, 'chrome': true, 'mac': true},
        'custom': [
          {'id': 'k', 'base_url': 'http://x/v1', 'model': 'm', 'computer_use': true},
          {'id': 'j', 'base_url': 'http://x/v1', 'model': 'm'},
        ],
      }),
      const {},
    );
    expect([for (final t in c.types) t.extras.length], [1, 2, 1, 0]);
    expect(c.types[1].toInfo()['extras'], ['chrome', 'mac_control']);
    final f = File('${tmp.path}/again.json');
    c.save(f);
    final again = WorkerTypesConfig.load(f, const {});
    expect([for (final t in again.types) (t.computerUse, t.chrome, t.mac)],
        [(true, false, false), (false, true, true), (true, false, false), (false, false, false)]);
    expect(WorkerTypesConfig.load(File('${tmp.path}/none.json'), const {}).types.every((t) => t.extras.isEmpty), isTrue);
  });

  test('the machine: project folder and workers at once; per-type limits for Codex and Claude', () {
    final c = WorkerTypesConfig.load(
      write({
        'project_dir': '~/work',
        'max_workers': 2,
        'codex': {'enabled': true, 'max_concurrent': 1, 'model': 'gpt-small'},
      }),
      const {},
    );
    expect((c.projectDir, c.maxWorkers), ('~/work', 2));
    expect((c.types.first.maxConcurrent, c.types.first.model), (1, 'gpt-small'));
    expect(WorkerTypesConfig.load(File('${tmp.path}/none.json'), const {}).maxWorkers, 4);
    final f = File('${tmp.path}/again.json');
    c.save(f);
    expect(jsonDecode(f.readAsStringSync())['codex'], {'enabled': true, 'model': 'gpt-small', 'max_concurrent': 1});
  });
}
