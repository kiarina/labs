import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aec_audio/aec_audio.dart';
import 'package:record/record.dart';

import 'capture_native.dart';

void main() => runApp(const MaterialApp(home: Probe()));

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _Probe();
}

class _Probe extends State<Probe> {
  String status = 'starting';
  @override
  void initState() {
    super.initState();
    unawaited(run());
  }

  void log(String value) {
    debugPrint('ANDROID_AEC $value');
    if (mounted) setState(() => status = value);
  }

  Future<void> run() async {
    final aec = AecAudio(),
        record = AudioRecorder(),
        camera = createCamera(Object());
    final raw = BytesBuilder(copy: false),
        clean = BytesBuilder(copy: false),
        reference = BytesBuilder(copy: false),
        mixed = BytesBuilder(copy: false),
        near = BytesBuilder(copy: false);
    final phases = <Map<String, dynamic>>[], errors = <String>[];
    int micBytes = 0, cleanBytes = 0, video = 0, renderBytes = 0, sample = 0;
    int lastAudio = 0, lastVideo = 0, maxAudioGap = 0, maxVideoGap = 0;
    final clock = Stopwatch()..start();
    bool speaking = false, nearActive = false;
    int captureSample = 0, mixedClippedSamples = 0;
    String recordingSource = "mic";
    StreamSubscription<Uint8List>? sub;
    Timer? timer;
    Future<void> captures = Future.value(), renders = Future.value();
    try {
      await aec.configure(enabled: true, delayMs: 80);
      final supported =
          (await aec.stats())['supportsUnprocessedSource'] == 'true';
      final selectedSource = supported
          ? AndroidAudioSource.unprocessed
          : AndroidAudioSource.mic;
      recordingSource = supported
          ? 'unprocessed'
          : 'mic-fallback-unprocessed-unsupported';
      if (!await record.hasPermission()) throw StateError('mic permission');
      sub =
          (await record.startStream(
            RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: 48000,
              numChannels: 1,
              echoCancel: false,
              noiseSuppress: false,
              autoGain: false,
              audioInterruption: AudioInterruptionMode.none,
              androidConfig: AndroidRecordConfig(
                audioSource: selectedSource,
                manageBluetooth: false,
                audioManagerMode: AudioManagerMode.modeInCommunication,
              ),
            ),
          )).listen((bytes) {
            final now = clock.elapsedMicroseconds;
            if (lastAudio > 0) {
              maxAudioGap = math.max(maxAudioGap, now - lastAudio);
            }
            lastAudio = now;
            micBytes += bytes.length;
            raw.add(Uint8List.fromList(bytes));
            final input = Uint8List.fromList(bytes),
                nearBytes = Uint8List(bytes.length);
            final view = ByteData.sublistView(input),
                nearView = ByteData.sublistView(nearBytes);
            for (int i = 0; i < bytes.length ~/ 2; i++, captureSample++) {
              final t = captureSample / 48000;
              final n = nearActive
                  ? (6000 *
                            (.4 +
                                .6 *
                                    math.pow(
                                      math.sin(2 * math.pi * 3.73 * t),
                                      2,
                                    )) *
                            (.5 * math.sin(2 * math.pi * 541 * t) +
                                .3 * math.sin(2 * math.pi * 1097 * t) +
                                .2 * math.sin(2 * math.pi * 1733 * t)))
                        .round()
                  : 0;
              final value = view.getInt16(i * 2, Endian.little) + n;
              if (value < -32768 || value > 32767) mixedClippedSamples++;
              view.setInt16(i * 2, value.clamp(-32768, 32767), Endian.little);
              nearView.setInt16(i * 2, n, Endian.little);
            }
            mixed.add(input);
            near.add(nearBytes);
            captures = captures
                .then((_) async {
                  final out = await aec.capture(input);
                  cleanBytes += out.length;
                  clean.add(out);
                })
                .catchError((Object e) {
                  errors.add('$e');
                });
          }, onError: (Object e) => errors.add('$e'));
      await camera.start((_, w, h, t) {
        video++;
        final now = clock.elapsedMicroseconds;
        if (lastVideo > 0) maxVideoGap = math.max(maxVideoGap, now - lastVideo);
        lastVideo = now;
      });
      timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final data = ByteData(960);
        for (var i = 0; i < 480; i++, sample++) {
          final t = sample / 48000;
          final f = 330 + 2200 * ((t * .71) % 1);
          final envelope =
              .25 + .75 * math.pow(math.sin(2 * math.pi * 2.13 * t), 2);
          final value = speaking
              ? (2250 *
                        envelope *
                        (.65 * math.sin(2 * math.pi * f * t) +
                            .35 * math.sin(2 * math.pi * 701 * t)))
                    .round()
              : 0;
          data.setInt16(i * 2, value, Endian.little);
        }
        final bytes = data.buffer.asUint8List();
        reference.add(bytes);
        renderBytes += bytes.length;
        renders = renders.then((_) => aec.render(bytes)).catchError((Object e) {
          errors.add('$e');
        });
      });
      for (final spec in [
        ('baseline', false, 3, false),
        ('near-only', false, 6, true),
        ('far-1-warmup', true, 6, false),
        ('far-1', true, 6, false),
        ('doubletalk', true, 6, true),
        ('quiet-between', false, 3, false),
        ('far-2', true, 6, false),
        ('quiet-after', false, 3, false),
      ]) {
        speaking = spec.$2;
        nearActive = spec.$4;
        log(spec.$1);
        final start = {
          'rawByte': micBytes,
          'cleanByte': cleanBytes,
          'renderByte': renderBytes,
          'video': video,
        };
        final startStats = await aec.stats();
        await Future<void>.delayed(Duration(seconds: spec.$3));
        await captures;
        phases.add({
          'name': spec.$1,
          'speakerSignal': spec.$2,
          'digitalNearEnd': spec.$4,
          'seconds': spec.$3,
          'start': start,
          'end': {
            'rawByte': micBytes,
            'cleanByte': cleanBytes,
            'renderByte': renderBytes,
            'video': video,
          },
          'startStats': startStats,
          'endStats': await aec.stats(),
        });
      }
    } catch (e, st) {
      errors.add('$e\n$st');
    } finally {
      timer?.cancel();
      await renders;
      await captures;
      await sub?.cancel();
      await record.dispose();
      await camera.dispose();
      await aec.dispose();
    }
    final directory = Directory.systemTemp;
    final rendered = await const MethodChannel('aec_audio')
        .invokeMethod<Uint8List>('renderTrace');
    if (rendered != null) {
      await File('${directory.path}/android_aec_actual_render.pcm')
          .writeAsBytes(rendered);
    }
    await File('${directory.path}/android_aec_raw.pcm')
        .writeAsBytes(raw.takeBytes());
    await File('${directory.path}/android_aec_clean.pcm')
        .writeAsBytes(clean.takeBytes());
    await File('${directory.path}/android_aec_reference.pcm')
        .writeAsBytes(reference.takeBytes());
    await File('${directory.path}/android_aec_mixed.pcm')
        .writeAsBytes(mixed.takeBytes());
    await File('${directory.path}/android_aec_near.pcm')
        .writeAsBytes(near.takeBytes());
    final report = {
      'platform': 'android',
      'recordingSource': recordingSource,
      'farPcmPeakBound': 2250,
      'digitalNearPeakBound': 6000,
      'mixedClippedSamples': mixedClippedSamples,
      'sampleRate': 48000,
      'captureStarts': {'microphone': 1, 'camera': 1},
      'maxAudioGapMs': maxAudioGap / 1000,
      'maxVideoGapMs': maxVideoGap / 1000,
      'phases': phases,
      'errors': errors,
    };
    await File('${directory.path}/android_aec_result.json')
        .writeAsString(jsonEncode(report));
    log('DONE ${jsonEncode(report)}');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Android AEC acoustic probe')),
    body: Text(status),
  );
}
