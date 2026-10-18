import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audio_analysis/audio_analysis.dart';

import 'backend_native.dart' as backend;
import 'pipeline.dart';
import 'probe.dart';
import 'stream_types.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(
            'Memory soak running. Metrics are written to the journal.',
          ),
        ),
      ),
    ),
  );
  unawaited(run());
}

int setting(String key, int fallback) =>
    int.tryParse(Platform.environment[key] ?? '') ?? fallback;
Future<void> run() async {
  final label = Platform.environment['RUN_LABEL'] ?? 'probe';
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(label))
    throw ArgumentError('RUN_LABEL');
  final mode = Platform.environment['RUN_MODE'] ?? 'full',
      passes = setting('PASSES', 12),
      seconds = setting('MEDIA_SECONDS', 600);
  final d = await getApplicationSupportDirectory();
  await d.create(recursive: true);
  final journal = File('${d.path}/$label.jsonl');
  await journal.writeAsString('');
  Future<void> emit(Map<String, Object?> row) async {
    await journal.writeAsString(
      '${jsonEncode(row)}\n',
      mode: FileMode.append,
      flush: true,
    );
    print('MEMORY_ROW ${jsonEncode(row)}');
  }

  final clock = Stopwatch()..start();
  OnnxModel? model;
  try {
    print('MEMORY_PID=$pid');
    if (Platform.environment['WORK_ACTIVITY'] == '1') await beginWork();
    final service = await developer.Service.getInfo();
    if (service.serverUri != null)
      print('MEMORY_VM_SERVICE=${service.serverUri}');
    if (mode == 'full' || mode == 'infer') model = await backend.loadVad();
    await emit({
      'type': 'start',
      'mode': mode,
      'passes': passes,
      'seconds': seconds,
      'clean_callbacks': cleanCallbacks,
      'ort_threads': setting('ORT_THREADS', 2),
      'work_activity': Platform.environment['WORK_ACTIVITY'] == '1',
      'utc': DateTime.now().toUtc().toIso8601String(),
      'metrics': await snapshot(),
    });
    for (var i = 0; i < passes; i++) {
      final work = Stopwatch()..start();
      final p = model == null ? null : PcmAnalysis(model);
      final images = FrameAnalysis();
      int bytes = 0;
      Map<String, Object?>? stream;
      if (mode == 'idle')
        await Future<void>.delayed(
          Duration(seconds: setting('IDLE_SECONDS', 1)),
        );
      else if (mode == 'infer') {
        final file = File(
          Platform.environment['PCM_INPUT'] ?? 'work/inference.pcm',
        );
        await for (final raw in file.openRead()) {
          final block = raw is Uint8List ? raw : Uint8List.fromList(raw);
          for (var k = 0; k < block.length; k += 3200) {
            final b = Uint8List.sublistView(
              block,
              k,
              (k + 3200).clamp(0, block.length),
            );
            bytes += b.length;
            await p!.add(b);
          }
        }
      } else {
        stream = await backend.streamDecode(StreamCase('$mode-$i', seconds), (
          b,
          t,
        ) async {
          bytes += b.length;
          await p?.add(b);
        }, images.add);
      }
      p?.finish();
      final row = <String, Object?>{
        'type': 'pass',
        'pass': i + 1,
        'mode': mode,
        'wall_ms': clock.elapsedMilliseconds,
        'work_ms': work.elapsedMilliseconds,
        'samples': bytes ~/ 2,
        'vad_positive': p?.positive,
        'voice_count': p?.voiceCount,
        'voice_retained': p?.voices.length,
        'frames': images.totalFrames,
        'frames_retained': images.frames.length,
        'metrics': await snapshot(),
      };
      if (mode != 'idle' && bytes ~/ 2 != seconds * 16000)
        throw StateError('sample count ${bytes ~/ 2}');
      if (mode == 'full' && images.totalFrames != seconds)
        throw StateError('frame count');
      if (stream != null)
        row['buffers'] = {
          'pcm': stream['max_audio_payload_bytes'],
          'jpeg': stream['max_jpeg_buffer_bytes'],
        };
      await emit(row);
      if (setting('GAP_MS', 0) > 0)
        await Future<void>.delayed(
          Duration(milliseconds: setting('GAP_MS', 0)),
        );
    }
    await emit({
      'type': 'before_close',
      'wall_ms': clock.elapsedMilliseconds,
      'metrics': await snapshot(),
    });
    await model?.close();
    model = null;
    await emit({'type': 'after_close', 'metrics': await snapshot()});
    if (setting('RELIEVE_AT_END', 0) == 1) {
      final released = await relieve();
      await emit({
        'type': 'pressure_relief',
        'released': released,
        'metrics': await snapshot(),
      });
    }
    await emit({
      'type': 'done',
      'ok': true,
      'wall_ms': clock.elapsedMilliseconds,
    });
  } catch (e, st) {
    print(st);
    await emit({
      'type': 'done',
      'ok': false,
      'error': e.toString(),
      'wall_ms': clock.elapsedMilliseconds,
    });
  } finally {
    await model?.close();
    if (Platform.environment['WORK_ACTIVITY'] == '1') await endWork();
  }
  print('MEMORY_DONE=$label');
  if (Platform.environment['STAY_ALIVE'] == '1')
    await Future<void>.delayed(const Duration(minutes: 30));
  exit(0);
}
