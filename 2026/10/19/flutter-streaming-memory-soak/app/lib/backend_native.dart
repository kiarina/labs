import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:audio_analysis/audio_analysis.dart';

import 'stream_types.dart';
import 'probe.dart';

Future<OnnxModel> loadVad() async {
  final d = await getApplicationSupportDirectory();
  await d.create(recursive: true);
  final f = File('${d.path}/silero_vad.onnx');
  final b = await rootBundle.load('assets/silero_vad.onnx');
  await f.writeAsBytes(b.buffer.asUint8List());
  return FlutterOnnxBackend(
    threads: int.tryParse(Platform.environment['ORT_THREADS'] ?? '2') ?? 2,
  ).load(f.path);
}

Future<String> inputPath() async {
  if (Platform.environment['MEDIA_INPUT'] case final String p) return p;
  if (Platform.isAndroid)
    return (await const MethodChannel('streaming_lab/input')
        .invokeMethod<String>('path'))!;
  final exe = File(Platform.resolvedExecutable).parent;
  final candidates = [
    '${exe.path}/data/flutter_assets/assets/long.mp4',
    '${exe.parent.path}/Frameworks/App.framework/Resources/flutter_assets/assets/long.mp4',
    '${exe.path}/Frameworks/App.framework/flutter_assets/assets/long.mp4',
  ];
  for (final p in candidates) {
    if (await File(p).exists()) return p;
  }
  throw StateError('Bundled input path not found');
}

Map<String, int> memory() => {
  'rss': ProcessInfo.currentRss,
  'peak_rss': ProcessInfo.maxRss,
};

Future<Map<String, Object?>> streamDecode(
  StreamCase config,
  Future<void> Function(Uint8List, double) audio,
  Future<void> Function(Uint8List, double) image,
) async {
  final path = await inputPath();
  final as = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final vs = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final done = Completer<int?>();
  final sockets = <Socket>[];
  int? id;
  bool cancelled = false;
  var audioSamples = 0, audioBytes = 0, frame = 0, maxAudio = 0, maxJpeg = 0;
  final clock = Stopwatch()..start();
  int? firstPcm, firstJpeg, producerDone, cancelRequested, cancelDone;
  Future<void> stop() async {
    if (cancelled) return;
    cancelled = true;
    cancelRequested = clock.elapsedMilliseconds;
    for (final s in sockets) {
      s.destroy();
    }
    if (id != null) await FFmpegKit.cancel(id);
  }

  Object? consumerError;
  Future<void> readAudio() async {
    try {
      final socket = await as.first.timeout(const Duration(seconds: 20));
      sockets.add(socket);
      await for (final bytes in socket) {
        if (cancelled) break;
        // At most 100 ms per analysis call, independent of socket event size.
        for (var i = 0; i < bytes.length && !cancelled; i += 3200) {
          final b = Uint8List.sublistView(
            bytes,
            i,
            (i + 3200).clamp(0, bytes.length),
          );
          maxAudio = maxAudio > b.length ? maxAudio : b.length;
          firstPcm ??= clock.elapsedMilliseconds;
          await audio(b, audioSamples / 16000);
          audioBytes += b.length;
          audioSamples = audioBytes ~/ 2;
          if (config.delayMs > 0)
            await Future<void>.delayed(
              Duration(microseconds: config.delayMs * 1000 * b.length ~/ 3200),
            );
          if (config.cancelAfterSeconds > 0 &&
              audioSamples >= config.cancelAfterSeconds * 16000) {
            await stop();
            break;
          }
        }
      }
    } catch (e) {
      if (!cancelled) {
        consumerError = e;
        await stop();
      }
    }
  }

  Future<void> readVideo() async {
    final parser = JpegChunks(maxBytes: 256 * 1024);
    try {
      final socket = await vs.first.timeout(const Duration(seconds: 20));
      sockets.add(socket);
      await for (final b in socket) {
        if (cancelled) break;
        for (final jpeg in parser.add(b)) {
          maxJpeg = maxJpeg > parser.peakBytes ? maxJpeg : parser.peakBytes;
          if (cancelled) break;
          firstJpeg ??= clock.elapsedMilliseconds;
          await image(jpeg, .5 + frame++);
        }
      }
      if (!cancelled) parser.finish();
    } catch (e) {
      if (!cancelled) {
        consumerError = e;
        await stop();
      }
    }
  }

  final readers = [readAudio(), readVideo()];
  try {
    final session = await FFmpegKit.executeWithArgumentsAsync(
      [
        '-v',
        'error',
        '-nostdin',
        '-threads',
        '1',
        '-filter_threads',
        '1',
        '-t',
        '${config.durationSeconds}',
        '-i',
        path,
        '-map',
        '0:a:0',
        '-af',
        'aresample=16000,atrim=end_sample=${config.durationSeconds * 16000},asetpts=N/SR/TB',
        '-t',
        '${config.durationSeconds}',
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-f',
        's16le',
        'tcp://127.0.0.1:${as.port}?tcp_nodelay=1',
        '-map',
        '0:v:0',
        '-an',
        '-vf',
        r'select=gte(t\,selected_n+0.5),scale=256:-2',
        '-fps_mode',
        'vfr',
        '-c:v',
        'mjpeg',
        '-q:v',
        '3',
        '-f',
        'image2pipe',
        'tcp://127.0.0.1:${vs.port}?tcp_nodelay=1',
      ],
      (s) async {
        producerDone = clock.elapsedMilliseconds;
        if (cancelled) cancelDone = clock.elapsedMilliseconds;
        done.complete((await s.getReturnCode())?.getValue());
      },
    );
    id = session.getSessionId();
    await Future.wait(readers).timeout(const Duration(minutes: 8));
    final code = await done.future.timeout(const Duration(seconds: 15));
    if (consumerError != null) throw consumerError!;
    if (!cancelled && !ReturnCode.isSuccess(ReturnCode(code!)))
      throw StateError(
        'FFmpeg code $code: ${await session.getAllLogsAsString()}',
      );
    return {
      'cancelled': cancelled,
      'return_code': code,
      'first_pcm_ms': firstPcm,
      'first_pcm_before_producer_done':
          firstPcm != null && producerDone != null && firstPcm! < producerDone!,
      'first_image_ms': firstJpeg,
      'producer_done_ms': producerDone,
      'elapsed_ms': clock.elapsedMilliseconds,
      'audio_samples': audioSamples,
      'frames': frame,
      'max_audio_payload_bytes': maxAudio,
      'max_jpeg_buffer_bytes': maxJpeg,
      'cancel_latency_ms': cancelRequested == null || cancelDone == null
          ? null
          : cancelDone! - cancelRequested!,
      'input_bytes': await File(path).length(),
      'ffmpeg': await FFmpegKitConfig.getFFmpegVersion(),
      'timestamp_policy': 'audio sample clock, nominal 0.5+n frame selection on zero-start CFR fixture',
    };
  } finally {
    if (!done.isCompleted && id != null) await FFmpegKit.cancel(id);
    for (final s in sockets) {
      s.destroy();
    }
    await as.close();
    await vs.close();
    if (id != null && cleanCallbacks) releaseCallbacks(id);
  }
}

Future<void> saveReport(Map<String, Object?> report) async {
  final d = await getApplicationSupportDirectory();
  await d.create(recursive: true);
  await File('${d.path}/stream-report.json').writeAsString(jsonEncode(report));
  print('STREAM_REPORT_PATH=${d.path}/stream-report.json');
}

void done() {
  if (const bool.fromEnvironment('AUTO_EXIT')) exit(0);
}

String get platform => Platform.operatingSystem;
String get cases =>
    Platform.environment['STREAM_CASES'] ??
    const String.fromEnvironment(
      'CASES',
      defaultValue: '60,600,slow,cancel,restart',
    );
