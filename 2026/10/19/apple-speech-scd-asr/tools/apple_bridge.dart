import 'dart:convert';
import 'dart:io';

// Lab transport proof: Dart owns IDs; Swift owns only a native ASR request.
Future<void> main() async {
  final expected = (jsonDecode(
    await File('fixtures/segments.json').readAsString(),
  ) as List).map((e) => e as Map<String, dynamic>).toList();
  final watch = Stopwatch()..start();
  final process = await Process.run('.build/release/segment-asr', [
    'work/apple-requests.json',
  ]);
  if (process.exitCode != 0) {
    stderr.write(process.stderr);
    exit(process.exitCode);
  }
  final result = jsonDecode(process.stdout as String) as Map<String, dynamic>;
  final rows = result['rows'] as List;
  for (final raw in rows) {
    final row = raw as Map<String, dynamic>;
    final request = expected.singleWhere((e) => e['id'] == row['id']);
    if (request['speaker_id'] != row['speaker_id']) {
      throw StateError('ASR result belongs to a different speaker request');
    }
    row['source_start'] = request['start'];
    row['source_end'] = request['end'];
    row['binding'] = 'request_id';
  }
  result['dart_process_wall_seconds'] = watch.elapsedMicroseconds / 1e6;
  result['transport'] =
      'Dart Process -> Swift native helper; same process for 18 requests';
  result['binding_verified'] = rows.length == expected.length * 3;
  await File('results/apple.json')
      .writeAsString('${const JsonEncoder.withIndent('  ').convert(result)}\n');
  stdout.writeln(
    'Apple native results: ${rows.length} request bindings verified',
  );
}
