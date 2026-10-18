import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Lab bridge constructs tracks from registered native IDs.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/media_stream_impl.dart';
import 'package:aec_audio/aec_audio.dart';
import 'package:record/record.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_taps/media_taps.dart';

import 'native_bridge.dart';

import 'capture_native.dart';
import 'platform/platform.dart';

class FarFixture {
  static Int16List? speech;
  static int speechGain = 1;
  int speechIndex = 0;
  int state = 123456789;
  double low = 0, slow = 0;
  int next() {
    if (speech != null) {
      return (speech![(speechIndex++) % speech!.length] * speechGain).clamp(
        -27000,
        27000,
      );
    }
    state ^= state << 13;
    state &= 0xffffffff;
    state ^= state >> 17;
    state ^= state << 5;
    state &= 0xffffffff;
    final white = state / 4294967296 * 2 - 1;
    low = .63 * low + .37 * white;
    slow = .965 * slow + .035 * white;
    return (9000 * (low - slow)).round().clamp(-9000, 9000);
  }
}

void main() => runApp(const MaterialApp(home: Probe()));

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _Probe();
}

class _Probe extends State<Probe> {
  String status = '準備できました。普段の位置で開始を押してください。';
  String instruction = '';
  int secondsLeft = 0;
  bool running = false, finished = false, aborted = false;
  @override
  void initState() {
    super.initState();
  }

  void log(String value) {
    debugPrint('AEC_PROBE $value');
    writeStatus(value);
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
    final comparisons = {
      for (final k in [
        'baseline',
        'candidate80',
        'linear80',
        'longRefined100',
        'longRefined120',
      ])
        k: BytesBuilder(copy: false),
    };
    final farFixture = FarFixture();
    String selectedMic = "not selected", videoSource = "not started";
    int cameraStarts = 0;
    final phases = <Map<String, dynamic>>[], errors = <String>[];
    final transport = _TransportGate(errors);
    Future<void>? humanTransport;
    final transportPhases = <Map<String, dynamic>>[];
    int micBytes = 0, cleanBytes = 0, video = 0, renderBytes = 0, sample = 0;
    int lastAudio = 0, lastVideo = 0, maxAudioGap = 0, maxVideoGap = 0;
    final clock = Stopwatch()..start();
    bool speaking = false;
    int captureSample = 0, mixedClippedSamples = 0;
    String recordingSource = "mic";
    Map<String, dynamic>? captureStoppedStats;
    StreamSubscription<Uint8List>? sub;
    Timer? timer, videoTimer;
    Future<void> captures = Future.value(), renders = Future.value();
    transport.rawSourceBytes = () => micBytes;
    transport.deviceStats = aec.stats;
    transport.wallUs = () => clock.elapsedMicroseconds;
    try {
      FarFixture.speechGain = (int.tryParse(envValue('far_gain') ?? '1') ?? 1)
          .clamp(1, 2);
      if (envValue('fixture') == 'speech') {
        final data = await rootBundle.load('assets/far_speech.pcm');
        FarFixture.speech = data.buffer.asInt16List(
          data.offsetInBytes,
          data.lengthInBytes ~/ 2,
        );
      }
      log('aec.configure before');
      await transport.initialize();
      await aec.configure(
        enabled: true,
        delayMs: int.tryParse(envValue('delay_ms') ?? '80') ?? 80,
      );
      log('aec.configure after');
      final supported =
          (await aec.stats())['supportsUnprocessedSource'] == 'true';
      final selectedSource = supported
          ? AndroidAudioSource.unprocessed
          : AndroidAudioSource.mic;
      recordingSource = Platform.environment['AEC_RECORD_RAW'] == '1'
          ? 'record_windows WASAPI shared RAW requested; fixed endpoint'
          : 'record_windows Media Foundation fixed endpoint; unprocessed capture is not guaranteed';
      log('record.hasPermission before');
      final permitted = await record.hasPermission();
      log('record.hasPermission after: $permitted');
      if (!permitted) throw StateError('mic permission');
      final devices = await record.listInputDevices();
      final wanted = envValue('mic') ?? 'DualSense';
      final selected = devices.firstWhere(
        (d) => d.label.toLowerCase().contains(wanted.toLowerCase()),
        orElse: () =>
            throw StateError('Requested microphone unavailable: $wanted'),
      );
      selectedMic = selected.label;
      log('record.startStream before');
      sub =
          (await record.startStream(
            RecordConfig(
              device: selected,
              encoder: AudioEncoder.pcm16bits,
              sampleRate: 48000,
              numChannels: 1,
              echoCancel: false,
              noiseSuppress: false,
              autoGain: false,
              audioInterruption: AudioInterruptionMode.none,
              iosConfig: IosRecordConfig(
                categoryOptions: [
                  IosAudioCategoryOption.defaultToSpeaker,
                  IosAudioCategoryOption.mixWithOthers,
                ],
              ),
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
              const n =
                  0; // Physical participant only; no synthetic near injection.
              final value = view.getInt16(i * 2, Endian.little) + n;
              if (value < -32768 || value > 32767) mixedClippedSamples++;
              view.setInt16(i * 2, value.clamp(-32768, 32767), Endian.little);
              nearView.setInt16(i * 2, n, Endian.little);
            }
            mixed.add(input);
            near.add(nearBytes);
            captures = captures
                .then((_) async {
                  final outputs = await aec.captureCompare(input);
                  for (final entry in outputs.entries) {
                    comparisons[entry.key]!.add(entry.value);
                  }
                  final out = outputs[envValue('output') ?? 'baseline']!;
                  cleanBytes += out.length;
                  clean.add(out);
                  transport.audio(out);
                })
                .catchError((Object e) {
                  errors.add('$e');
                });
          }, onError: (Object e) => errors.add('$e'));
      log('record.startStream after');
      log('camera.start before');
      void frame(Uint8List pixels, int w, int h, int stamp) {
        transport.frame(pixels, w, h, stamp);
        video++;
        final now = clock.elapsedMicroseconds;
        if (lastVideo > 0) maxVideoGap = math.max(maxVideoGap, now - lastVideo);
        lastVideo = now;
      }

      try {
        if (envValue('camera_mode') == 'synthetic') {
          throw StateError(
            'explicit synthetic fixture; physical camera unavailable',
          );
        }
        await camera.start(frame).timeout(const Duration(seconds: 8));
        cameraStarts = 1;
        videoSource = 'camera';
      } catch (error) {
        videoSource = 'synthetic fallback: $error';
        videoTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
          const w = 320, h = 240;
          final pixels = Uint8List(w * h * 4);
          for (var i = 0; i < pixels.length; i += 4) {
            pixels[i] = 30;
            pixels[i + 1] = 70 + video % 100;
            pixels[i + 2] = 160;
            pixels[i + 3] = 255;
          }
          frame(pixels, w, h, clock.elapsedMicroseconds);
        });
      }
      timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final data = ByteData(960);
        for (var i = 0; i < 480; i++, sample++) {
          final excitation = farFixture.next();
          final value = speaking ? excitation : 0;
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
        ('baseline', false, 4, false),
        ('near-only', false, 10, true),
        ('far-1-warmup', true, 12, false),
        ('far-1', true, 6, false),
        ('doubletalk', true, 16, true),
        ('quiet-between', false, 3, false),
        ('far-2', true, 6, false),
        ('near-recovery', false, 8, true),
        ('quiet-after', false, 3, false),
      ]) {
        speaking = spec.$2;
        log(spec.$1);
        instruction = spec.$4
            ? (spec.$1 == 'doubletalk'
                  ? '相手の声と重ねて、普段の声で繰り返してください。\n「今日は窓を開けて、部屋の空気を入れ替えました。明日は駅前のお店で、温かいコーヒーを飲みたいです。」'
                  : '普段の声で、繰り返してください。\n「今日は朝から天気がよく、散歩に出かけました。公園には赤い花と白い花が咲いていました。」')
            : '話さず、そのままお待ちください。相手の音声が流れることがあります。';
        if (spec.$1 == 'doubletalk') {
          humanTransport = transport.run(log, transportPhases).catchError((
            Object e,
          ) {
            errors.add('human transport: $e');
          });
        }
        final start = {
          'rawByte': micBytes,
          'cleanByte': cleanBytes,
          'renderByte': renderBytes,
          'video': video,
        };
        final startStats = await aec.stats();
        for (var left = spec.$3; left > 0; left--) {
          if (aborted) throw StateError('participant aborted');
          if (mounted) setState(() => secondsLeft = left);
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        await captures;
        phases.add({
          'name': spec.$1,
          'speakerSignal': spec.$2,
          'digitalNearEnd': false,
          'physicalHumanNearExpected': spec.$4,
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
      // Acoustic measurements above are complete. Keep their capture and render
      // running while separately testing two WebRTC sender gate transitions.
      speaking = false;
      instruction = '発話は終了しました。自動確認中です。静かにお待ちください。';
      await humanTransport;
      timer.cancel();
      await renders;
      await aec.stopRender();
      log('RTC received far playback');
      final farStart = {
        'rawByte': micBytes,
        'cleanByte': cleanBytes,
        'renderByte': renderBytes,
        'video': video,
      };
      final farStats = await aec.stats();
      final farReport = await _receivedFar(aec);
      await captures;
      phases.add({
        'name': 'rtc-far-playback',
        'speakerSignal': true,
        'digitalNearEnd': false,
        'seconds': 6,
        'start': farStart,
        'end': {
          'rawByte': micBytes,
          'cleanByte': cleanBytes,
          'renderByte': renderBytes,
          'video': video,
        },
        'startStats': farStats,
        'endStats': await aec.stats(),
        'receivedFar': farReport,
      });
    } catch (e, st) {
      errors.add('$e\n$st');
    } finally {
      timer?.cancel();
      videoTimer?.cancel();
      await renders;
      // Stop acquisition before waiting for sender cleanup, including on abort.
      await sub?.cancel();
      await captures;
      await record.dispose();
      await camera.dispose();
      if (humanTransport != null) {
        try {
          await humanTransport;
        } catch (e) {
          errors.add('humanTransport: $e');
        }
      }
      captureStoppedStats = await aec.stats();
      if (captureStoppedStats.containsKey('recordRawAuditError')) {
        errors.add('${captureStoppedStats["recordRawAuditError"]}');
      } else {
        final audit = captureStoppedStats['recordRawAudit'] as Map;
        if (Platform.environment['AEC_RECORD_RAW'] == '1' &&
            (audit['rawRequests'] != 1 ||
                audit['rawPropertiesAccepted'] != 1 ||
                audit['rawStarts'] != 1 ||
                audit['mfCreateRequests'] != 0 ||
                (audit['nativeCaptureFrames'] as num) <= 0)) {
          errors.add(
            'RAW capture ownership/initialization audit failed: $audit',
          );
        }
        if (audit['activeRawCaptures'] != 0 || audit['lastHresult'] != 0) {
          errors.add('RAW capture did not stop cleanly: $audit');
        }
      }
      await transport.dispose();
      try {
        await File('${Directory.systemTemp.path}/aec_actual_render.pcm')
            .writeAsBytes(await aec.renderTrace());
      } catch (e) {
        errors.add('renderTrace: $e');
      }
      await aec.dispose();
    }
    final directory = Directory.systemTemp;
    await File('${directory.path}/aec_raw.pcm').writeAsBytes(raw.takeBytes());
    await File('${directory.path}/aec_clean.pcm')
        .writeAsBytes(clean.takeBytes());
    await File('${directory.path}/aec_reference.pcm')
        .writeAsBytes(reference.takeBytes());
    await File('${directory.path}/aec_mixed.pcm')
        .writeAsBytes(mixed.takeBytes());
    await File('${directory.path}/aec_near.pcm').writeAsBytes(near.takeBytes());
    for (final entry in comparisons.entries) {
      await File('${directory.path}/aec_${entry.key}.pcm')
          .writeAsBytes(entry.value.takeBytes());
    }
    await File('${directory.path}/human_received.pcm')
        .writeAsBytes(transport.received.takeBytes());
    final report = {
      'kind': 'physical-human-doubletalk',
      'platform': Platform.operatingSystem,
      'syntheticNearInjection': false,
      'participantAborted': aborted,
      'receiverChunks': transport.receiverChunks,
      'recordingSource': recordingSource,
      'captureStoppedStats': captureStoppedStats,
      'sentVariant': envValue('output') ?? 'baseline',
      'farPcmPeakBound': 9000 * FarFixture.speechGain,
      'farSpeechGain': FarFixture.speechGain,
      'fixture': envValue('fixture') == 'speech'
          ? 'shared conversation_2speaker_14s_16k resampled48k base peak9000; farSpeechGain applied'
          : 'aperiodic xorshift32 lowpass difference, 0.63/0.965, seed123456789',
      'selectedMicrophone': selectedMic,
      'comparison': 'same input: baseline, external80, linear80, longRefined100/120; selected EXTERNAL_OUTPUT (default baseline) sent to WebRTC',
      'digitalNearPeakBound': 0,
      'mixedClippedSamples': mixedClippedSamples,
      'sampleRate': 48000,
      'captureStarts': {'microphone': 1, 'camera': cameraStarts},
      'videoSource': videoSource,
      'maxAudioGapMs': maxAudioGap / 1000,
      'maxVideoGapMs': maxVideoGap / 1000,
      'phases': phases,
      'transportPhases': transportPhases,
      'transport': {
        'input': 'standalone AEC cleaned PCM and the same camera BGRA frames',
        'totals': transport.counts(),
        'rawRecordingContainsTransportTail': true,
        'nearEndDuringTransport':
            'physical participant voice; no synthetic near signal',
        'receiverPlayback': 'manual SDK mixer pull; discarded during transport gate, explicitly routed to WASAPI in received-far phase',
        'acousticAnalysisExcludesTransport': true,
        'pass':
            errors.isEmpty &&
            transportPhases.length == 5 &&
            transportPhases.every((p) => p['pass'] == true),
      },
      'errors': errors,
    };
    await File('${directory.path}/aec_result.json')
        .writeAsString(jsonEncode(report));
    log('DONE ${jsonEncode(report)}');
    if (mounted) {
      setState(() {
        finished = true;
        instruction = '完了しました。録音を回収しています。';
      });
    }
    if (envValue('exit') == 'true') exitApp();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('実人声 AEC テスト')),
    body: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'マイクを普段の位置に置き、スピーカーを使います。録音はローカル保存です。',
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 28),
          Text(
            instruction.isEmpty ? status : instruction,
            style: const TextStyle(fontSize: 30),
          ),
          const SizedBox(height: 20),
          if (running && !finished)
            Text(
              '残り $secondsLeft 秒（この区間）',
              style: const TextStyle(fontSize: 26),
            ),
          if (!running)
            ElevatedButton(
              onPressed: () {
                setState(() => running = true);
                unawaited(run());
              },
              child: const Text('開始（約70秒＋自動確認）'),
            ),
          if (running && !finished)
            TextButton(
              onPressed: () => setState(() => aborted = true),
              child: const Text('中止'),
            ),
          const Spacer(),
          Text(status.length > 160 ? status.substring(0, 160) : status),
        ],
      ),
    ),
  );
}

/// A sender gate, independent of AEC and physical capture ownership.
/// No getUserMedia, device reopen, remote-track disabling or local-ID lookup.
class _TransportGate {
  _TransportGate(this.errors);
  final List<String> errors;
  final CaptureBridge bridge = CaptureBridge();
  final received = BytesBuilder(copy: false);
  final receiverChunks = <Map<String, dynamic>>[];
  int Function()? wallUs;
  int Function()? rawSourceBytes;
  Future<Map<String, dynamic>> Function()? deviceStats;
  MediaStream? stream;
  bool sending = false, audioBusy = false, videoBusy = false;
  int sourceAudio = 0, sourceVideo = 0;
  int injectedAudio = 0, injectedVideo = 0, droppedAudio = 0, droppedVideo = 0;

  void audio(Uint8List pcm) {
    sourceAudio += pcm.length;
    if (!sending || pcm.isEmpty) return;
    if (audioBusy) {
      droppedAudio += pcm.length;
      return;
    }
    audioBusy = true;
    bridge
        .pushAudio(pcm)
        .then((_) {
          injectedAudio += pcm.length;
        })
        .catchError((Object e) {
          errors.add('transport audio: $e');
        })
        .whenComplete(() => audioBusy = false);
  }

  void frame(Uint8List pixels, int width, int height, int timestampUs) {
    sourceVideo++;
    if (!sending) return;
    if (videoBusy) {
      droppedVideo++;
      return;
    }
    videoBusy = true;
    bridge
        .pushVideo(pixels, width, height, timestampUs)
        .then((_) {
          injectedVideo++;
        })
        .catchError((Object e) {
          errors.add('transport video: $e');
        })
        .whenComplete(() => videoBusy = false);
  }

  Map<String, int> counts() => {
    'sourceRawAudioBytes': rawSourceBytes?.call() ?? 0,
    'sourceCleanAudioBytes': sourceAudio,
    'sourceVideoFrames': sourceVideo,
    'injectedCleanAudioBytes': injectedAudio,
    'injectedVideoFrames': injectedVideo,
    'droppedCleanAudioBytes': droppedAudio,
    'droppedVideoFrames': droppedVideo,
  };
  Map<String, int> delta(Map<String, int> before) {
    final after = counts();
    return {for (final key in before.keys) key: after[key]! - before[key]!};
  }

  Future<void> initialize() async {
    stream ??= await bridge.create();
  }

  Future<void> stop() async {
    sending = false;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (audioBusy || videoBusy) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('transport pushes');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (stream != null) await bridge.flush();
  }

  Future<void> dispose() async {
    await stop();
    if (stream != null) {
      await bridge.dispose();
      stream = null;
    }
  }

  Future<Map<String, dynamic>> idle(String name) async {
    final before = counts();
    final hardwareBefore = await deviceStats?.call();
    await Future<void>.delayed(const Duration(seconds: 3));
    final d = delta(before);
    return {
      'name': name,
      'seconds': 3,
      'deviceBefore': hardwareBefore,
      'deviceAfter': await deviceStats?.call(),
      ...d,
      'pass':
          d['sourceRawAudioBytes']! >= 48000 * 2 * 3 * .7 &&
          d['sourceCleanAudioBytes']! >= 48000 * 2 * 3 * .7 &&
          d['sourceVideoFrames']! >= 15 &&
          d['injectedCleanAudioBytes'] == 0 &&
          d['injectedVideoFrames'] == 0,
    };
  }

  Future<void> run(
    void Function(String) log,
    List<Map<String, dynamic>> phases,
  ) async {
    log('transport idle-before');
    phases.add(await idle('idle-before'));
    for (var cycle = 1; cycle <= 2; cycle++) {
      log('transport send-$cycle setup');
      RTCPeerConnection? sender, receiver;
      final tapIds = <int>[];
      Object? attachmentError;
      final audioAttached = Completer<void>(),
          videoAttached = Completer<void>();
      try {
        sender = await createPeerConnection({
          'iceServers': [],
          'sdpSemantics': 'unified-plan',
        });
        receiver = await createPeerConnection({
          'iceServers': [],
          'sdpSemantics': 'unified-plan',
        });
        receiver.onTrack = (event) {
          final ready = event.track.kind == 'audio'
              ? audioAttached
              : videoAttached;
          unawaited(
            MediaTaps.instance
                .attach(
                  event.track,
                  local: false,
                  stream: event.streams.isEmpty ? null : event.streams.first,
                  options: const TapOptions(convertWidth: 160, deliver: true),
                )
                .then((id) {
                  tapIds.add(id);
                  if (!ready.isCompleted) ready.complete();
                })
                .catchError((Object error, StackTrace stack) {
                  attachmentError = error;
                  if (!ready.isCompleted) ready.complete();
                }),
          );
        };
        for (final track in stream!.getTracks()) {
          await sender.addTrack(track, stream!);
        }
        await sender.setLocalDescription(await sender.createOffer());
        await _gather(sender);
        await receiver.setRemoteDescription(
          (await sender.getLocalDescription())!,
        );
        await receiver.setLocalDescription(await receiver.createAnswer());
        await _gather(receiver);
        await sender.setRemoteDescription(
          (await receiver.getLocalDescription())!,
        );
        await Future.wait([audioAttached.future, videoAttached.future])
            .timeout(const Duration(seconds: 10));
        if (attachmentError != null) {
          throw StateError('Tap attachment failed: $attachmentError');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await MediaTaps.instance
            .poll(); // discard setup silence and queued frames
        final beforeStats = await _inbound(receiver);
        final hardwareBefore = await deviceStats?.call();
        await bridge.flush();
        final before = counts();
        final receiverStartByte = received.length;
        double squares = 0;
        int samples = 0, frames = 0;
        sending = true;
        log('transport send-$cycle');
        for (var poll = 0; poll < 60; poll++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          for (final tap in await MediaTaps.instance.poll()) {
            if (!tapIds.contains(tap.id)) continue;
            if (tap.kind == TapKind.video) frames += tap.frames.length;
            if (tap.kind == TapKind.audio && tap.pcm != null) {
              receiverChunks.add({
                'clockUs': wallUs?.call(),
                'startByte': received.length,
                'bytes': tap.pcm!.lengthInBytes,
                'sampleRate': tap.counters['sampleRate'],
                'channels': tap.counters['channels'],
                'droppedToDart': tap.counters['droppedToDart'],
              });
              received.add(
                tap.pcm!.buffer.asUint8List(
                  tap.pcm!.offsetInBytes,
                  tap.pcm!.lengthInBytes,
                ),
              );
              for (final sample in tap.pcm!) {
                final value = sample / 32768;
                squares += value * value;
              }
              samples += tap.pcm!.length;
            }
          }
        }
        await stop();
        final d = delta(before), afterStats = await _inbound(receiver);
        final packets =
            _sum(afterStats, 'audio', 'packetsReceived') -
            _sum(beforeStats, 'audio', 'packetsReceived');
        final decodedSamples =
            _sum(afterStats, 'audio', 'totalSamplesReceived') -
            _sum(beforeStats, 'audio', 'totalSamplesReceived');
        final decodedFrames =
            _sum(afterStats, 'video', 'framesDecoded') -
            _sum(beforeStats, 'video', 'framesDecoded');
        final rms = samples == 0 ? 0.0 : math.sqrt(squares / samples);
        phases.add({
          'name': 'send-$cycle',
          'minimumSeconds': 6,
          'deviceBefore': hardwareBefore,
          'deviceAfter': await deviceStats?.call(),
          ...d,
          'receiver': {
            'pcmSamples': samples,
            'pcmStartByte': receiverStartByte,
            'pcmEndByte': received.length,
            'videoFrames': frames,
            'rms': rms,
          },
          'inboundBefore': beforeStats,
          'inboundAfter': afterStats,
          'inboundDelta': {
            'audioPacketsReceived': packets,
            'audioSamplesReceived': decodedSamples,
            'videoFramesDecoded': decodedFrames,
          },
          'pass':
              d['sourceRawAudioBytes']! >= 48000 * 2 * 6 * .7 &&
              d['sourceCleanAudioBytes']! >= 48000 * 2 * 6 * .7 &&
              d['sourceVideoFrames']! >= 30 &&
              d['injectedCleanAudioBytes']! > 0 &&
              d['injectedVideoFrames']! > 0 &&
              samples > 0 &&
              frames > 0 &&
              rms > 1e-6 &&
              packets > 0 &&
              decodedSamples > 0 &&
              decodedFrames > 0,
        });
      } finally {
        await stop();
        for (final tap in tapIds) {
          await MediaTaps.instance.detach(tap);
        }
        await sender?.close();
        await receiver?.close();
        await sender?.dispose();
        await receiver?.dispose();
      }
      log('transport idle-after-$cycle');
      phases.add(await idle('idle-after-$cycle'));
    }
    return;
  }

  static Future<List<Map<String, dynamic>>> _inbound(
    RTCPeerConnection pc,
  ) async => [
    for (final stat in await pc.getStats())
      if (stat.type == 'inbound-rtp') {'id': stat.id, ...stat.values},
  ];
  static double _sum(
    List<Map<String, dynamic>> rows,
    String kind,
    String key,
  ) => rows
      .where((row) => (row['kind'] ?? row['mediaType']) == kind)
      .fold(0.0, (total, row) => total + ((row[key] as num?)?.toDouble() ?? 0));
  static Future<void> _gather(RTCPeerConnection pc) async {
    for (var i = 0; i < 50; i++) {
      if (pc.iceGatheringState ==
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('transport ICE gathering');
  }
}

/// A separate device-free far source crosses Opus/RTP and the receiver mixer
/// before the same WASAPI output/reference path. No near receiver remains open.
Future<Map<String, dynamic>> _receivedFar(AecAudio aec) async {
  const channel = MethodChannel('external_capture'),
      speaker = MethodChannel('aec_audio');
  final ids = (await channel.invokeMapMethod<String, dynamic>('createFar'))!;
  final stream = MediaStreamNative.fromMap({
    'streamId': ids['streamId'],
    'ownerTag': 'local',
    'audioTracks': [
      {
        'id': ids['audioTrackId'],
        'label': 'remote-fixture',
        'kind': 'audio',
        'enabled': true,
        'settings': <String, dynamic>{},
      },
    ],
    'videoTracks': <dynamic>[],
  });
  final sender = await createPeerConnection({
    'iceServers': [],
    'sdpSemantics': 'unified-plan',
  });
  final receiver = await createPeerConnection({
    'iceServers': [],
    'sdpSemantics': 'unified-plan',
  });
  Future<void> pending = Future.value();
  Timer? timer;
  int samples = 0, bytes = 0;
  final errors = <String>[];
  try {
    await sender.addTrack(stream.getAudioTracks().single, stream);
    await sender.setLocalDescription(await sender.createOffer());
    await _TransportGate._gather(sender);
    await receiver.setRemoteDescription((await sender.getLocalDescription())!);
    await receiver.setLocalDescription(await receiver.createAnswer());
    await _TransportGate._gather(receiver);
    await sender.setRemoteDescription((await receiver.getLocalDescription())!);
    await speaker.invokeMethod('setNativePlayout', {'enabled': true});
    final before = await _TransportGate._inbound(receiver);
    final deviceBefore = await aec.stats();
    final remoteFixture = FarFixture();
    timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final pcm = ByteData(960);
      for (var i = 0; i < 480; i++, samples++) {
        pcm.setInt16(i * 2, remoteFixture.next(), Endian.little);
      }
      pending = pending
          .then((_) async {
            await channel.invokeMethod('pushFarAudio', {
              'bytes': pcm.buffer.asUint8List(),
            });
            bytes += 960;
          })
          .catchError((Object e) {
            errors.add('$e');
          });
    });
    await Future<void>.delayed(const Duration(seconds: 6));
    timer.cancel();
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final after = await _TransportGate._inbound(receiver),
        deviceAfter = await aec.stats();
    final packets =
        _TransportGate._sum(after, 'audio', 'packetsReceived') -
        _TransportGate._sum(before, 'audio', 'packetsReceived');
    final decoded =
        _TransportGate._sum(after, 'audio', 'totalSamplesReceived') -
        _TransportGate._sum(before, 'audio', 'totalSamplesReceived');
    return {
      'source': 'auxiliary custom far source -> Opus/RTP -> native receiver mixer -> WASAPI -> AEC reverse',
      'injectedBytes': bytes,
      'audioPacketsReceived': packets,
      'audioSamplesReceived': decoded,
      'beforeStats': before,
      'afterStats': after,
      'deviceBefore': deviceBefore,
      'deviceAfter': deviceAfter,
      'errors': errors,
      'pass':
          errors.isEmpty &&
          bytes >= 48000 * 2 * 6 * .7 &&
          packets > 0 &&
          decoded > 0 &&
          (deviceAfter['playbackHeadFrames'] as num) >
              (deviceBefore['playbackHeadFrames'] as num),
    };
  } finally {
    timer?.cancel();
    await pending;
    await aec.stopRender();
    await sender.close();
    await receiver.close();
    await sender.dispose();
    await receiver.dispose();
  }
}
