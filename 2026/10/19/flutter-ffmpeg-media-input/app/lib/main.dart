import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'backend.dart' as backend;
import 'pipeline.dart';

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
  String status = 'Ready';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    if (backend.autoMode != '')
      WidgetsBinding.instance.addPostFrameCallback((_) {
        run(backend.autoMode);
      });
  }

  Future<void> run(String mode) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = 'Running $mode';
    });
    final report = <String, Object?>{
      'platform': backend.platform,
      'mode': mode,
      'utc': DateTime.now().toUtc().toIso8601String(),
    };
    final sw = Stopwatch()..start();
    try {
      final model = await backend.loadVad();
      final p = PcmAnalysis(model);
      final images = FrameAnalysis();
      try {
        if (mode == 'mic') {
          final r = AudioRecorder();
          StreamSubscription<Uint8List>? sub;
          Future<void> queue = Future.value();
          int pending = 0, maxPending = 0;
          try {
            report['devices'] = [
              for (final d in await r.listInputDevices()) {'label': d.label},
            ];
            if (!await r.hasPermission())
              throw StateError('Microphone permission denied');
            final stream = await r.startStream(
              const RecordConfig(
                encoder: AudioEncoder.pcm16bits,
                sampleRate: 16000,
                numChannels: 1,
              ),
            );
            sub = stream.listen((b) {
              final copy = Uint8List.fromList(b);
              pending++;
              if (pending > maxPending) maxPending = pending;
              queue = queue.then((_) async {
                try {
                  await p.add(copy);
                } finally {
                  pending--;
                }
              });
            });
            await Future<void>.delayed(
              const Duration(
                seconds: int.fromEnvironment('MIC_SECONDS', defaultValue: 5),
              ),
            );
            await r.stop();
            await sub.cancel();
            sub = null;
            await queue;
            report['max_pending_chunks'] = maxPending;
          } finally {
            await sub?.cancel();
            await r.dispose();
          }
        } else {
          report['file'] = await backend.decode(p.add, images.add);
        }
        p.finish();
        report['audio'] = p.report();
        report['images'] = images.frames;
        report['ok'] = p.samples > 0;
      } finally {
        await model.close();
      }
    } catch (e, st) {
      report['ok'] = false;
      report['error'] = e.toString();
      print(st);
    }
    report['elapsed_ms'] = sw.elapsedMilliseconds;
    await backend.saveReport(report);
    final json = jsonEncode(report);
    for (var i = 0; i < json.length; i += 700) {
      print(
        'MEDIA_REPORT ${i ~/ 700} ${json.substring(i, (i + 700).clamp(0, json.length))}',
      );
    }
    print('MEDIA_DONE');
    if (mounted)
      setState(() {
        busy = false;
        status = const JsonEncoder.withIndent(' ').convert(report);
      });
    backend.done();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Media input lab')),
    body: Column(
      children: [
        Wrap(
          children: [
            FilledButton(
              onPressed: busy ? null : () => run('file'),
              child: const Text('Decode video → VAD'),
            ),
            FilledButton(
              onPressed: busy ? null : () => run('mic'),
              child: const Text('Microphone → VAD (5s)'),
            ),
          ],
        ),
        Expanded(child: SingleChildScrollView(child: SelectableText(status))),
      ],
    ),
  );
}
