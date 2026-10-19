import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final segments = (jsonDecode(
    await File('fixtures/segments.json').readAsString(),
  ) as List).cast<Map<String, dynamic>>();
  final clock = Stopwatch()..start();
  final process = await Process.start('.build/release/segment-asr', [
    '--serve',
  ]);
  final errors = StringBuffer();
  final errorSub = process.stderr.transform(utf8.decoder).listen(errors.write);
  final replies = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final rows = <Map<String, dynamic>>[];
  try {
    if (!await replies.moveNext().timeout(const Duration(seconds: 30)))
      throw StateError('No ready');
    final ready = jsonDecode(replies.current) as Map<String, dynamic>;
    if (ready['type'] != 'ready') throw StateError('Unexpected ready');
    final startupMs = clock.elapsedMicroseconds / 1000;
    // Alternate identities, then reverse identities; requests carry no reference text.
    for (final index in [0, 1, 2, 3, 4, 5, 5, 4, 3, 2, 1, 0]) {
      final segment = segments[index];
      final request = {
        for (final key in ['id', 'speaker_id', 'start', 'end', 'path'])
          key: segment[key],
      };
      final watch = Stopwatch()..start();
      process.stdin.writeln(jsonEncode(request));
      await process.stdin.flush();
      if (!await replies.moveNext().timeout(const Duration(seconds: 30)))
        throw StateError('No result');
      final reply = jsonDecode(replies.current) as Map<String, dynamic>;
      final row = reply['row'] as Map<String, dynamic>;
      if (reply['type'] != 'result' ||
          row['id'] != request['id'] ||
          row['speaker_id'] != request['speaker_id'])
        throw StateError('Request mismatch');
      rows.add({
        ...row,
        'dart_roundtrip_ms': watch.elapsedMicroseconds / 1000,
        'binding_ok': true,
      });
    }
    await process.stdin.close();
    if (await process.exitCode.timeout(const Duration(seconds: 10)) != 0)
      throw StateError(errors.toString());
    await File('results/dart-stream.json').writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'startup_ms': startupMs, 'rows': rows, 'single_process': true, 'reference_text_sent': false})}\n',
    );
    stdout.writeln('Dart live request/reply bindings verified: ${rows.length}');
  } finally {
    process.kill();
    await replies.cancel();
    await errorSub.cancel();
  }
}
