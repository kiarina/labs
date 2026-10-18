import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_taps/media_taps.dart';
import 'package:record/record.dart';

import 'native_bridge.dart' if (dart.library.js_interop) 'web_bridge.dart';
import 'capture_native.dart' if (dart.library.js_interop) 'capture_web.dart';
import 'platform/platform.dart';

void main() => runApp(const MaterialApp(home: Experiment()));

class Experiment extends StatefulWidget {
  const Experiment({super.key});
  @override
  State<Experiment> createState() => _ExperimentState();
}

class _ExperimentState extends State<Experiment> {
  String status = 'Starting';
  String? output;
  RTCVideoRenderer? renderer;
  void log(String s) {
    debugPrint('EXTERNAL_STATUS $s');
    writeStatus(s);
    if (mounted) setState(() => status = s);
  }

  @override
  void initState() {
    super.initState();
    unawaited(run());
  }

  Future<void> run() async {
    final report = <String, dynamic>{
      'platform': defaultTargetPlatform.name,
      'web': kIsWeb,
      'phases': <Object>[],
    };
    final bridge = CaptureBridge();
    final recorder = AudioRecorder();
    // Conditional imports select the correct factory without dart:io on Web.
    final capture = createCamera(bridge);
    StreamSubscription<Uint8List>? audioSub;
    Timer? syntheticTimer;
    var send = false, videoBusy = false, audioBusy = false;
    int videoCount = 0,
        audioBytes = 0,
        videoInjected = 0,
        audioInjected = 0,
        videoDropped = 0,
        audioDropped = 0;
    int videoLast = 0, audioLast = 0, videoGap = 0, audioGap = 0;
    final clock = Stopwatch()..start();
    final errors = <String>[];
    void video(Uint8List data, int w, int h, int ts) {
      final now = clock.elapsedMicroseconds;
      if (videoLast > 0) videoGap = math.max(videoGap, now - videoLast);
      videoLast = now;
      videoCount++;
      if (!send) return;
      if (videoBusy) {
        videoDropped++;
        return;
      }
      videoBusy = true;
      bridge
          .pushVideo(data, w, h, now)
          .then((_) {
            videoInjected++;
          })
          .catchError((Object e) {
            errors.add('$e');
          })
          .whenComplete(() => videoBusy = false);
    }

    void audio(Uint8List bytes) {
      final now = clock.elapsedMicroseconds;
      if (audioLast > 0) audioGap = math.max(audioGap, now - audioLast);
      audioLast = now;
      audioBytes += bytes.length;
      if (!send) return;
      if (audioBusy) {
        audioDropped += bytes.length;
        return;
      }
      audioBusy = true;
      bridge
          .pushAudio(bytes)
          .then((_) {
            audioInjected += bytes.length;
          })
          .catchError((Object e) {
            errors.add('$e');
          })
          .whenComplete(() => audioBusy = false);
    }

    Map<String, int> counts() => {
      'sourceVideoFrames': videoCount,
      'sourceAudioBytes': audioBytes,
      'injectedVideoFrames': videoInjected,
      'injectedAudioBytes': audioInjected,
      'busyDroppedVideo': videoDropped,
      'busyDroppedAudioBytes': audioDropped,
    };
    Future<void> idle(String name) async {
      log(name);
      final before = counts();
      await Future<void>.delayed(const Duration(seconds: 3));
      final after = counts();
      final delta = {for (final k in before.keys) k: after[k]! - before[k]!};
      (report['phases'] as List).add({
        'name': name,
        ...delta,
        'pass':
            delta['sourceVideoFrames']! > 0 &&
            delta['sourceAudioBytes']! > 0 &&
            delta['injectedVideoFrames'] == 0 &&
            delta['injectedAudioBytes'] == 0,
      });
    }

    MediaStream? stream;
    try {
      log('Create external tracks (no getUserMedia in flutter_webrtc)');
      stream = await bridge.create();
      report['tracks'] = stream
          .getTracks()
          .map((t) => {'id': t.id, 'kind': t.kind})
          .toList();
      final synthetic = envValue('synthetic') == 'true';
      report['synthetic'] = synthetic;
      if (synthetic) {
        var tick = 0, sample = 0;
        syntheticTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
          final pcm = ByteData(960 * 2);
          for (var i = 0; i < 960; i++) {
            pcm.setInt16(
              i * 2,
              (math.sin(2 * math.pi * 440 * sample++ / 48000) * 8000).round(),
              Endian.little,
            );
          }
          audio(pcm.buffer.asUint8List());
          if (tick++ % 2 == 0) {
            final frame = Uint8List(320 * 240 * 4);
            for (var i = 0; i < frame.length; i += 4) {
              frame[i] = 40;
              frame[i + 1] = (tick % 100) * 2;
              frame[i + 2] = 180;
              frame[i + 3] = 255;
            }
            video(frame, 320, 240, clock.elapsedMicroseconds);
          }
        });
      } else {
        log('Request microphone permission');
        if (!await recorder.hasPermission()) {
          throw StateError('Microphone permission denied');
        }
        log('Start record');
        audioSub = (await recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 48000,
            numChannels: 1,
            echoCancel: false,
            noiseSuppress: false,
            autoGain: false,
            audioInterruption: AudioInterruptionMode.none,
          ),
        )).listen(audio, onError: (Object e) => errors.add('$e'));
        log('Start camera');
        await capture.start(video);
      }
      report['captureStarts'] = {'camera': 1, 'microphone': 1};
      await idle('idle-before');
      for (var cycle = 1; cycle <= 2; cycle++) {
        log('send-$cycle setup');
        final a = await createPeerConnection({
          'iceServers': [],
          'sdpSemantics': 'unified-plan',
        });
        final b = await createPeerConnection({
          'iceServers': [],
          'sdpSemantics': 'unified-plan',
        });
        final tapIds = <int>[];
        final pending = <Future<void>>[];
        final remote = await createLocalMediaStream('remote-holder-$cycle');
        b.onTrack = (event) {
          pending.add(() async {
            await remote.addTrack(event.track, addToNative: false);
            final id = await MediaTaps.instance.attach(
              event.track,
              local: false,
              stream: event.streams.isEmpty ? null : event.streams.first,
              options: const TapOptions(convertWidth: 160, deliver: true),
            );
            tapIds.add(id);
          }());
        };
        try {
          for (final t in stream.getTracks()) {
            await a.addTrack(t, stream);
          }
          await a.setLocalDescription(await a.createOffer());
          await gathered(a);
          await b.setRemoteDescription((await a.getLocalDescription())!);
          await b.setLocalDescription(await b.createAnswer());
          await gathered(b);
          await a.setRemoteDescription((await b.getLocalDescription())!);
          await Future.wait(pending);
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await bridge.flush();
          send = true;
          final before = counts();
          final rows = <Map<String, dynamic>>[];
          final receiver = <String, Map<String, dynamic>>{};
          log('send-$cycle');
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            for (final tap in await MediaTaps.instance.poll()) {
              final key = tap.kind.name;
              final aggregate = receiver.putIfAbsent(
                key,
                () => {
                  'polls': 0,
                  'pcmBytes': 0,
                  'videoFrames': 0,
                  'sumSquares': 0.0,
                  'samples': 0,
                },
              );
              aggregate['polls'] = (aggregate['polls'] as int) + 1;
              aggregate['last'] = tap.counters;
              final pcm = tap.pcm;
              if (pcm != null) {
                aggregate['pcmBytes'] =
                    (aggregate['pcmBytes'] as int) + pcm.length * 2;
                double sum = aggregate['sumSquares'] as double;
                for (final sample in pcm) {
                  final v = sample / 32768;
                  sum += v * v;
                }
                aggregate['sumSquares'] = sum;
                aggregate['samples'] =
                    (aggregate['samples'] as int) + pcm.length;
              }
              aggregate['videoFrames'] =
                  (aggregate['videoFrames'] as int) + tap.frames.length;
            }
          }
          send = false;
          while (videoBusy || audioBusy) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          await bridge.flush();
          final after = counts();
          final stats = await b.getStats();
          for (final s in stats) {
            if (s.type == 'inbound-rtp') {
              rows.add({'type': s.type, ...s.values});
            }
          }
          for (final value in receiver.values) {
            final n = value['samples'] as int;
            value['rms'] = n > 0
                ? math.sqrt((value['sumSquares'] as double) / n)
                : null;
          }
          final audioOk =
              (receiver['audio']?['pcmBytes'] as int? ?? 0) > 0 &&
              after['sourceAudioBytes']! > before['sourceAudioBytes']! &&
              after['injectedAudioBytes']! > before['injectedAudioBytes']! &&
              (!synthetic ||
                  (receiver['audio']?['rms'] as double? ?? 0) > 0.05);
          final videoOk = (receiver['video']?['videoFrames'] as int? ?? 0) > 0;
          (report['phases'] as List).add({
            'name': 'send-$cycle',
            for (final k in before.keys) k: after[k]! - before[k]!,
            'receiver': receiver,
            'inboundStats': rows,
            'pass': audioOk && videoOk,
          });
        } finally {
          send = false;
          for (final id in tapIds) {
            await MediaTaps.instance.detach(id);
          }
          await a.close();
          await b.close();
          await a.dispose();
          await b.dispose();
          await remote.dispose();
        }
        await idle('idle-after-$cycle');
      }
      report['maxSourceGapMs'] = {
        'video': videoGap / 1000,
        'audio': audioGap / 1000,
      };
      report['totals'] = counts();
      report['errors'] = errors;
      report['pass'] =
          (report['phases'] as List).every((dynamic p) => p['pass'] == true) &&
          errors.isEmpty;
    } catch (e, st) {
      report['pass'] = false;
      report['error'] = '$e';
      report['stack'] = '$st';
    } finally {
      syntheticTimer?.cancel();
      await audioSub?.cancel();
      await recorder.dispose();
      await capture.dispose();
      await bridge.dispose();
    }
    final encoded = jsonEncode(report);
    debugPrint('EXTERNAL_RESULT $encoded');
    writeResult(encoded);
    if (mounted) {
      setState(() {
        status = report['pass'] == true ? 'PASS' : 'FAIL';
        output = const JsonEncoder.withIndent('  ').convert(report);
      });
    }
    if (envValue('exit') == 'true') exitApp();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('External capture — $status')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(output ?? status),
    ),
  );
}

Future<void> gathered(RTCPeerConnection pc) async {
  for (var i = 0; i < 50; i++) {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('ICE gathering');
}
