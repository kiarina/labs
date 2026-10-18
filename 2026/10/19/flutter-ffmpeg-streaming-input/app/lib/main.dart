import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'backend.dart' as backend;
import 'pipeline.dart';
import 'stream_types.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Lab()));
}

class Lab extends StatefulWidget {
  const Lab({super.key});
  @override
  State<Lab> createState() => _LabState();
}

class _LabState extends State<Lab> {
  String status = 'Running streaming suite';
  bool running = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      run();
    });
  }

  Future<void> run() async {
    if (running) return;
    running = true;
    final report = <String, Object?>{
      'platform': backend.platform,
      'utc': DateTime.now().toUtc().toIso8601String(),
      'cases': <Object?>[],
    };
    final start = Stopwatch()..start();
    try {
      final model = await backend.loadVad();
      report['model_ready_ms'] = start.elapsedMilliseconds;
      try {
        for (final name in backend.cases.split(',')) {
          final c = StreamCase.parse(name), p = PcmAnalysis(model);
          final images = FrameAnalysis();
          final clock = Stopwatch()..start();
          int? firstVoice;
          int memoryBucket = -1;
          final samples = <Map<String, Object?>>[];
          int peakRss = 0;
          int maxPending = 0, pending = 0;
          void sample() {
            final m = backend.memory();
            peakRss = (m['rss'] ?? 0) > peakRss ? (m['rss'] ?? 0) : peakRss;
            final bucket = (p.samples / 16000 / 30).floor();
            if (bucket != memoryBucket) {
              memoryBucket = bucket;
              samples.add({
                'media_s': p.samples / 16000,
                'wall_ms': clock.elapsedMilliseconds,
                ...m,
              });
            }
          }

          final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
            sample();
          });
          sample();
          try {
            final stats = await backend.streamDecode(c, (bytes, pts) async {
              pending++;
              if (pending > maxPending) maxPending = pending;
              try {
                await p.add(bytes);
                if (p.voiceCount > 0) firstVoice ??= clock.elapsedMilliseconds;
              } finally {
                pending--;
              }
            }, images.add);
            p.finish();
            sample();
            final expectedCancelled = c.cancelAfterSeconds > 0;
            final ok =
                stats['cancelled'] == expectedCancelled &&
                p.samples > 0 &&
                (expectedCancelled ||
                    (images.totalFrames == c.durationSeconds &&
                        p.samples == c.durationSeconds * 16000));
            (report['cases'] as List).add({
              'case': name,
              'ok': ok,
              'config': {
                'duration_s': c.durationSeconds,
                'consumer_delay_ms': c.delayMs,
              },
              'stream': stats,
              'audio': p.report(),
              'images': {'count': images.totalFrames, 'last': images.frames},
              'first_voice_ms': firstVoice,
              'max_pending_analysis_calls': maxPending,
              'rss_peak_sampled': peakRss == 0 ? null : peakRss,
              'memory_samples': samples,
            });
          } finally {
            timer.cancel();
          }
          if (mounted)
            setState(
              () => status =
                  '$name complete: ${p.samples / 16000} seconds, ${images.totalFrames} frames',
            );
        }
      } finally {
        await model.close();
      }
      report['ok'] = (report['cases'] as List).every((c) => c['ok'] == true);
    } catch (e, st) {
      report['ok'] = false;
      report['error'] = e.toString();
      print(st);
    }
    report['elapsed_ms'] = start.elapsedMilliseconds;
    await backend.saveReport(report);
    final s = jsonEncode(report);
    for (var i = 0; i < s.length; i += 700) {
      print(
        'STREAM_REPORT ${i ~/ 700} ${s.substring(i, (i + 700).clamp(0, s.length))}',
      );
    }
    print('STREAM_DONE');
    if (mounted)
      setState(
        () => status = const JsonEncoder.withIndent(' ').convert(report),
      );
    backend.done();
    running = false;
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Streaming input lab')),
    body: SingleChildScrollView(child: SelectableText(status)),
  );
}
