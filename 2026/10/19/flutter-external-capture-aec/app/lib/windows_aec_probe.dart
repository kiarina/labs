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
    final phases = <Map<String, dynamic>>[], errors = <String>[];
    final transport = _TransportGate(errors);
    final transportPhases = <Map<String, dynamic>>[];
    int micBytes = 0, cleanBytes = 0, video = 0, renderBytes = 0, sample = 0;
    int lastAudio = 0, lastVideo = 0, maxAudioGap = 0, maxVideoGap = 0;
    final clock = Stopwatch()..start();
    bool speaking = false, nearActive = false;
    int captureSample = 0, mixedClippedSamples = 0;
    String recordingSource = "mic";
    StreamSubscription<Uint8List>? sub;
    Timer? timer, videoTimer;
    Future<void> captures = Future.value(), renders = Future.value();
    transport.rawSourceBytes = () => micBytes;
    transport.deviceStats = aec.stats;
    try {
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
      recordingSource = supported
          ? 'unprocessed'
          : 'mic-fallback-unprocessed-unsupported';
      log('record.hasPermission before');
      final permitted = await record.hasPermission();
      log('record.hasPermission after: $permitted');
      if (!permitted) throw StateError('mic permission');
      log('record.startStream before');
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
                  transport.audio(out);
                })
                .catchError((Object e) {
                  errors.add('$e');
                });
          }, onError: (Object e) => errors.add('$e'));
      log('record.startStream after');
      log('camera.start before');
      // This machine exposes only unavailable virtual cameras. Keep a single
      // explicit synthetic video source; do not report physical camera capture.
      videoTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        const w = 320, h = 240;
        final pixels = Uint8List(w * h * 4);
        for (var i = 0; i < pixels.length; i += 4) {
          pixels[i] = 30;
          pixels[i + 1] = 70 + video % 100;
          pixels[i + 2] = 160;
          pixels[i + 3] = 255;
        }
        transport.frame(pixels, w, h, clock.elapsedMicroseconds);
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
      // Acoustic measurements above are complete. Keep their capture and render
      // running while separately testing two WebRTC sender gate transitions.
      speaking = false;
      nearActive = true; // known capture-only near-end ensures non-silent input
      log('transport setup (separate from acoustic measurements)');
      log('native bridge prepare/initialize/create before');
      await transport.initialize();
      log('native bridge prepare/initialize/create after');
      await transport.run(log, transportPhases);
      nearActive = false;
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
      await sub?.cancel();
      await captures;
      await record.dispose();
      await camera.dispose();
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
    final report = {
      'platform': Platform.operatingSystem,
      'recordingSource': recordingSource,
      'farPcmPeakBound': 2250,
      'digitalNearPeakBound': 6000,
      'mixedClippedSamples': mixedClippedSamples,
      'sampleRate': 48000,
      'captureStarts': {'microphone': 1, 'camera': 0},
      'videoSource': 'synthetic; no available physical Windows camera',
      'maxAudioGapMs': maxAudioGap / 1000,
      'maxVideoGapMs': maxVideoGap / 1000,
      'phases': phases,
      'transportPhases': transportPhases,
      'transport': {
        'input': 'standalone AEC cleaned PCM and the same camera BGRA frames',
        'totals': transport.counts(),
        'rawRecordingContainsTransportTail': true,
        'nearEndDuringTransport': 'digital fixture added only to capture',
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
    if (envValue('exit') == 'true') exitApp();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('External capture AEC')),
    body: Text(status),
  );
}

/// A sender gate, independent of AEC and physical capture ownership.
/// No getUserMedia, device reopen, remote-track disabling or local-ID lookup.
class _TransportGate {
  _TransportGate(this.errors);
  final List<String> errors;
  final CaptureBridge bridge = CaptureBridge();
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
    timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final pcm = ByteData(960);
      for (var i = 0; i < 480; i++, samples++) {
        final t = samples / 48000;
        final f = 330 + 2200 * ((t * .71) % 1);
        final env = .25 + .75 * math.pow(math.sin(2 * math.pi * 2.13 * t), 2);
        pcm.setInt16(
          i * 2,
          (2250 *
                  env *
                  (.65 * math.sin(2 * math.pi * f * t) +
                      .35 * math.sin(2 * math.pi * 701 * t)))
              .round(),
          Endian.little,
        );
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
