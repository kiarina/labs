import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:audio_analysis/audio_analysis.dart';

Future<OnnxModel> loadVad() async {
  final d = await getApplicationSupportDirectory();
  await d.create(recursive: true);
  final f = File('${d.path}/silero_vad.onnx');
  final b = await rootBundle.load('assets/silero_vad.onnx');
  await f.writeAsBytes(b.buffer.asUint8List());
  return FlutterOnnxBackend(threads: 2).load(f.path);
}

Future<Map<String, Object?>> decode(
  Future<void> Function(Uint8List) audio,
  Future<void> Function(Uint8List, double) image,
) async {
  final d = await Directory.systemTemp.createTemp('media-input-');
  try {
    final b = await rootBundle.load('assets/input.mp4');
    final path = '${d.path}/input.mp4';
    await File(path).writeAsBytes(b.buffer.asUint8List());
    final probe = await FFprobeKit.getMediaInformation(path);
    final commands = [
      [
        '-y',
        '-v',
        'error',
        '-i',
        path,
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-f',
        's16le',
        '${d.path}/audio.pcm',
      ],
      [
        '-y',
        '-v',
        'error',
        '-i',
        path,
        '-an',
        '-vf',
        r'select=gte(t\,selected_n+0.5),scale=256:-2,showinfo',
        '-fps_mode',
        'vfr',
        '-q:v',
        '3',
        '${d.path}/frame-%03d.jpg',
      ],
    ];
    commands[1][2] = 'info';
    final timestamps = <double>[];
    final sw = Stopwatch()..start();
    for (final args in commands) {
      final s = await FFmpegKit.executeWithArguments(args);
      if (identical(args, commands[1])) {
        final logs = await s.getAllLogsAsString() ?? '';
        for (final m in RegExp(r'pts_time:([0-9.]+)').allMatches(logs)) {
          timestamps.add(double.parse(m[1]!));
        }
      }
      if (!ReturnCode.isSuccess(await s.getReturnCode()))
        throw StateError(await s.getAllLogsAsString() ?? 'decode failed');
    }
    final decodeMs = sw.elapsedMilliseconds;
    final f = File('${d.path}/audio.pcm');
    final length = await f.length();
    // Deliberately odd chunk size exercises byte carry across every boundary.
    await for (final chunk in f.openRead().transform(_chunks(3199))) {
      await audio(Uint8List.fromList(chunk));
    }
    final frames = await d
        .list()
        .where((f) => f.path.endsWith('.jpg'))
        .toList();
    frames.sort((a, b) => a.path.compareTo(b.path));
    for (var i = 0; i < frames.length; i++) {
      await image(await File(frames[i].path).readAsBytes(), timestamps[i]);
    }
    final version = await FFmpegKitConfig.getFFmpegVersion();
    final info = await FFmpegKit.executeWithArguments(['-buildconf']);
    final configuration = await info.getAllLogsAsString() ?? '';
    final invalid = await FFmpegKit.executeWithArguments([
      '-v',
      'error',
      '-i',
      '/file-that-does-not-exist',
      '-f',
      'null',
      '-',
    ]);
    final cancelled = Completer<bool>();
    final running = await FFmpegKit.executeWithArgumentsAsync(
      ['-v', 'error', '-stream_loop', '-1', '-i', path, '-f', 'null', '-'],
      (s) async {
        cancelled.complete(ReturnCode.isCancel(await s.getReturnCode()));
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await FFmpegKit.cancel(running.getSessionId());
    final cancelOk = await cancelled.future.timeout(
      const Duration(seconds: 10),
    );
    return {
      'ffmpeg': version,
      'gpl_enabled': configuration.contains('--enable-gpl'),
      'nonfree_enabled': configuration.contains('--enable-nonfree'),
      'missing_input_failed': !ReturnCode.isSuccess(
        await invalid.getReturnCode(),
      ),
      'cancelled': cancelOk,
      'probe': {
        'duration': probe.getMediaInformation()?.getDuration(),
        'streams': probe
            .getMediaInformation()
            ?.getStreams()
            .map(
              (s) => {
                'type': s.getType(),
                'codec': s.getCodec(),
                'sample_rate': s.getSampleRate(),
                'width': s.getWidth(),
                'height': s.getHeight(),
              },
            )
            .toList(),
      },
      'decode_ms': decodeMs,
      'pcm_bytes': length,
      'frames': [
        for (var i = 0; i < frames.length; i++)
          {'pts': timestamps[i], 'bytes': await File(frames[i].path).length()},
      ],
      'timestamp_policy': 'source presentation timestamps; first frame at or after 0.5+n seconds',
      'build_date': await FFmpegKitConfig.getBuildDate(),
    };
  } finally {
    await d.delete(recursive: true);
  }
}

StreamTransformer<List<int>, List<int>> _chunks(int size) =>
    StreamTransformer.fromBind((s) async* {
      var p = <int>[];
      await for (final x in s) {
        p.addAll(x);
        while (p.length >= size) {
          yield p.sublist(0, size);
          p = p.sublist(size);
        }
      }
      if (p.isNotEmpty) yield p;
    });
Future<void> saveReport(Map<String, Object?> r) async {
  final d = await getApplicationSupportDirectory();
  await d.create(recursive: true);
  await File('${d.path}/report.json').writeAsString(jsonEncode(r));
  print('REPORT_PATH=${d.path}/report.json');
}

void done() {
  if (const bool.fromEnvironment('AUTO_EXIT')) exit(0);
}

String get platform => Platform.operatingSystem;

String get autoMode =>
    Platform.environment['MEDIA_MODE'] ?? const String.fromEnvironment('AUTO');
