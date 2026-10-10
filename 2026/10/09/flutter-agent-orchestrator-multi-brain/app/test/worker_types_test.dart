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

  test('no file: codex, claude and kiapi', () {
    final types = WorkerType.load(File('${tmp.path}/none.json'), {'KIAPI_BASE_URL': 'http://k:1/'});
    expect([for (final t in types) t.id], ['codex', 'claude', 'kiapi']);
    expect(types.last.baseUrl, 'http://k:1/v1');
    expect(types.last.maxConcurrent, 1);
  });

  test('custom types replace kiapi; the key is sent by name only', () {
    final types = WorkerType.load(
      write({
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
    expect([for (final t in types) t.id], ['codex', 'claude', 'local-qwen']);
    final info = types.last.toInfo();
    expect(info, {
      'id': 'local-qwen',
      'kind': 'custom',
      'label': 'local-qwen',
      'description': 'small tasks',
      'maxConcurrent': 2,
      'model': 'qwen',
    });
    expect(types.last.baseUrl, 'http://127.0.0.1:11434/v1');
    expect(jsonEncode(info).contains('SECRET'), isFalse);
  });

  test('bad configs are refused', () {
    expect(() => WorkerType.load(write({'custom': [{'id': 'codex', 'base_url': 'x', 'model': 'm'}]}), const {}),
        throwsFormatException);
    expect(() => WorkerType.load(write({'custom': [{'id': 'Bad Id', 'base_url': 'x', 'model': 'm'}]}), const {}),
        throwsFormatException);
    expect(() => WorkerType.load(write({'custom': [{'id': 'a'}]}), const {}), throwsFormatException);
    expect(
      () => WorkerType.load(
        write({
          'custom': [
            {'id': 'a', 'base_url': 'x', 'model': 'm'},
            {'id': 'a', 'base_url': 'y', 'model': 'n'},
          ],
        }),
        const {},
      ),
      throwsFormatException,
    );
  });
}
