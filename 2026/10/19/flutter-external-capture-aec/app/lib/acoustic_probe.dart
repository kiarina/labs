import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
    bool speaking = false, nearActive = false, localRenderEnabled = true;
    bool dspDisposed = false;
    Map<String, dynamic>? remoteFarPhase;
    const skipAcoustic = bool.fromEnvironment('SKIP_ACOUSTIC');
    const skipRemoteFar = bool.fromEnvironment('SKIP_REMOTE_FAR');
    int captureSample = 0, mixedClippedSamples = 0;
    String recordingSource = "mic";
    StreamSubscription<Uint8List>? sub;
    Timer? timer;
    Future<void> captures = Future.value(), renders = Future.value();
    transport.rawSourceBytes = () => micBytes;
    transport.deviceStats = () =>
        aec.stats().timeout(const Duration(seconds: 20));
    Future<void> cleanup(String name, Future<void> Function() action) async {
      log('$name before');
      try {
        await action().timeout(const Duration(seconds: 20));
      } catch (e) {
        errors.add('$name: $e');
      }
      log('$name after');
    }

    try {
      log('aec.configure before');
      await aec
          .configure(enabled: true, delayMs: 80)
          .timeout(const Duration(seconds: 20));
      log('aec.configure after');
      final supported =
          (await aec.stats().timeout(
            const Duration(seconds: 20),
          ))['supportsUnprocessedSource'] ==
          'true';
      final selectedSource = supported
          ? AndroidAudioSource.unprocessed
          : AndroidAudioSource.mic;
      recordingSource = supported
          ? 'unprocessed'
          : 'mic-fallback-unprocessed-unsupported';
      log('record.hasPermission before');
      final permitted = await record.hasPermission().timeout(
        const Duration(seconds: 20),
      );
      log('record.hasPermission after: $permitted');
      if (!permitted) throw StateError('mic permission');
      log('record.startStream before');
      sub =
          (await record
                  .startStream(
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
                  )
                  .timeout(const Duration(seconds: 20)))
              .listen((bytes) {
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
                  view.setInt16(
                    i * 2,
                    value.clamp(-32768, 32767),
                    Endian.little,
                  );
                  nearView.setInt16(i * 2, n, Endian.little);
                }
                mixed.add(input);
                near.add(nearBytes);
                captures = captures
                    .then((_) async {
                      if (dspDisposed) return;
                      final out = await aec
                          .capture(input)
                          .timeout(const Duration(seconds: 20));
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
      await camera
          .start((pixels, w, h, t) {
            transport.frame(pixels, w, h, clock.elapsedMicroseconds);
            video++;
            final now = clock.elapsedMicroseconds;
            if (lastVideo > 0) {
              maxVideoGap = math.max(maxVideoGap, now - lastVideo);
            }
            lastVideo = now;
          })
          .timeout(const Duration(seconds: 20));
      log('camera.start after');
      timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (!localRenderEnabled) return;
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
      if (!skipAcoustic) {
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
          log('${spec.$1} capture drain before');
          await captures.timeout(const Duration(seconds: 20));
          log('${spec.$1} capture drain after');
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
      }
      // Acoustic measurements above are complete. Keep their capture and render
      // running while separately testing two WebRTC sender gate transitions.
      speaking = false;
      nearActive = false;
      localRenderEnabled = false;
      await renders.timeout(const Duration(seconds: 20));
      await aec.stopRender().timeout(const Duration(seconds: 20));
      log('transport setup (separate from acoustic measurements)');
      log('native bridge prepare/initialize/create before');
      await transport.initialize().timeout(const Duration(seconds: 20));
      log('native bridge prepare/initialize/create after');
      if (!skipRemoteFar) {
        remoteFarPhase = await transport.remoteFar(aec, log);
      } else {
        remoteFarPhase = {
          'skipped': true,
          'reason': 'SKIP_REMOTE_FAR diagnostic build',
        };
      }
      nearActive = true; // capture-only near-end ensures non-silent gate input
      await transport.run(log, transportPhases);
      nearActive = false;
    } catch (e, st) {
      errors.add('$e\n$st');
    } finally {
      timer?.cancel();
      await cleanup('record subscription cancel', () async {
        await sub?.cancel();
      });
      await cleanup('render drain', () => renders);
      await cleanup('capture drain', () => captures);
      await cleanup('record.dispose', record.dispose);
      await cleanup('camera.dispose', camera.dispose);
      await cleanup('transport.dispose', transport.dispose);
      try {
        await File('${Directory.systemTemp.path}/aec_actual_render.pcm')
            .writeAsBytes(
              await aec.renderTrace().timeout(const Duration(seconds: 20)),
            );
      } catch (e) {
        errors.add('renderTrace: $e');
      }
      dspDisposed = true;
      await cleanup('aec.dispose', aec.dispose);
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
      'captureStarts': {'microphone': 1, 'camera': 1},
      'maxAudioGapMs': maxAudioGap / 1000,
      'maxVideoGapMs': maxVideoGap / 1000,
      'phases': phases,
      'diagnosticSkips': {'acoustic': skipAcoustic, 'remoteFar': skipRemoteFar},
      'remoteFarPhase': remoteFarPhase,
      'transportPhases': transportPhases,
      'transport': {
        'input': 'standalone AEC cleaned PCM and the same camera BGRA frames',
        'totals': transport.counts(),
        'rawRecordingContainsTransportTail': true,
        'nearEndDuringTransport': 'digital fixture added only to capture',
        'receiverPlayback': Platform.isMacOS || Platform.isIOS
            ? 'lab custom WebRTC ADM discards receiver playout'
            : 'Android lab patch disables native receiver playout; gate loopback is not rendered',
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
    debugPrint('AEC_RESULT ${jsonEncode(report)}');
    log(
      'DONE — errors: ${errors.length}; clean send gates: ${report['transport'] is Map && (report['transport'] as Map)['pass'] == true ? 'PASS' : 'FAIL'}. Details: aec_result.json',
    );
    if (envValue('exit') == 'true' && !Platform.isIOS) exitApp();
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
    stream = await bridge.create();
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

  /// The microphone is processed continuously but never injected into this
  /// phase's peer. Only a deterministic fixture enters the external audio track;
  /// decoded remote PCM is the sole source for the owned speaker/render path.
  Future<Map<String, dynamic>> remoteFar(
    AecAudio aec,
    void Function(String) log,
  ) async {
    await stop();
    RTCPeerConnection? sender, receiver;
    int? tapId;
    Object? attachError;
    final attached = Completer<void>();
    final rawStart = counts();
    final hardwareBefore = await deviceStats?.call();
    final reference = BytesBuilder(copy: false),
        received = BytesBuilder(copy: false);
    Future<void> playback = Future.value();
    Object? fixtureFailure, playbackFailure;
    int sentBytes = 0, receivedSamples = 0;
    double receivedSquares = 0;
    final name = 'remote-far-fixture';
    log('$name setup');
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
        if (event.track.kind != 'audio') return;
        unawaited(
          MediaTaps.instance
              .attach(
                event.track,
                local: false,
                stream: event.streams.isEmpty ? null : event.streams.first,
                options: const TapOptions(deliver: true),
              )
              .then((id) {
                tapId = id;
                if (!attached.isCompleted) attached.complete();
              })
              .catchError((Object error) {
                attachError = error;
                if (!attached.isCompleted) attached.complete();
              }),
        );
      };
      await sender.addTrack(stream!.getAudioTracks().single, stream!);
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
      await attached.future.timeout(const Duration(seconds: 10));
      if (attachError != null) throw StateError('Far remote tap: $attachError');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await MediaTaps.instance.poll();
      await bridge.flush();
      final beforeStats = await _inbound(receiver);
      final sourceBefore = counts();
      final timer = Stopwatch()..start();
      int fixtureSample = 0;
      final fixtureTask =
          () async {
            for (var block = 0; block < 300; block++) {
              final due = block * 20000 - timer.elapsedMicroseconds;
              if (due > 0) {
                await Future<void>.delayed(Duration(microseconds: due));
              }
              final pcm = ByteData(1920);
              for (var i = 0; i < 960; i++, fixtureSample++) {
                final t = fixtureSample / 48000;
                final f = 330 + 2200 * ((t * .71) % 1);
                final envelope =
                    .25 + .75 * math.pow(math.sin(2 * math.pi * 2.13 * t), 2);
                final value =
                    (2250 *
                            envelope *
                            (.65 * math.sin(2 * math.pi * f * t) +
                                .35 * math.sin(2 * math.pi * 701 * t)))
                        .round();
                pcm.setInt16(i * 2, value, Endian.little);
              }
              final bytes = pcm.buffer.asUint8List();
              reference.add(bytes);
              await bridge
                  .pushAudio(bytes)
                  .timeout(const Duration(seconds: 20));
              sentBytes += bytes.length;
            }
          }().catchError((Object error) {
            fixtureFailure = error;
          });
      log('$name fixture → WebRTC → remote PCM → owned speaker');
      while (timer.elapsedMilliseconds < 6500) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        for (final tap in await MediaTaps.instance.poll()) {
          if (tap.id != tapId || tap.kind != TapKind.audio || tap.pcm == null) {
            continue;
          }
          final rate = (tap.counters['sampleRate'] as num?)?.toInt() ?? 48000;
          final channels = (tap.counters['channels'] as num?)?.toInt() ?? 1;
          if (rate != 48000 || channels < 1) {
            throw StateError('Far receive format $rate Hz/$channels channels');
          }
          final pcm = tap.pcm!;
          final mono = ByteData((pcm.length ~/ channels) * 2);
          for (var frame = 0; frame < pcm.length ~/ channels; frame++) {
            var value = 0;
            for (var ch = 0; ch < channels; ch++) {
              value += pcm[frame * channels + ch];
            }
            value = (value / channels).round();
            mono.setInt16(frame * 2, value, Endian.little);
            final v = value / 32768;
            receivedSquares += v * v;
            receivedSamples++;
          }
          final bytes = mono.buffer.asUint8List();
          received.add(bytes);
          playback = playback
              .then(
                (_) => aec.render(bytes).timeout(const Duration(seconds: 20)),
              )
              .catchError((Object error) {
                playbackFailure = error;
              });
        }
      }
      await fixtureTask.timeout(const Duration(seconds: 20));
      await playback.timeout(const Duration(seconds: 20));
      if (fixtureFailure != null || playbackFailure != null) {
        throw StateError(
          'Far fixture: $fixtureFailure; playback: $playbackFailure',
        );
      }
      await bridge.flush();
      final afterStats = await _inbound(receiver);
      final sourceDelta = delta(sourceBefore);
      final packets =
          _sum(afterStats, 'audio', 'packetsReceived') -
          _sum(beforeStats, 'audio', 'packetsReceived');
      final decoded =
          _sum(afterStats, 'audio', 'totalSamplesReceived') -
          _sum(beforeStats, 'audio', 'totalSamplesReceived');
      final rms = receivedSamples == 0
          ? 0.0
          : math.sqrt(receivedSquares / receivedSamples);
      await File('${Directory.systemTemp.path}/aec_remote_far_fixture.pcm')
          .writeAsBytes(reference.takeBytes());
      await File('${Directory.systemTemp.path}/aec_remote_far_received.pcm')
          .writeAsBytes(received.takeBytes());
      return {
        'name': name,
        'fixtureSeconds': 6,
        'collectionSeconds': timer.elapsedMilliseconds / 1000,
        'route': 'fixture-only external track → dedicated peer pair → remote tap PCM → aec_audio.render',
        'microphoneInjected': false,
        'nativeReceiverPlayout':
            'disabled on Android; discarded by Darwin lab ADM',
        'rawByteStart': sourceBefore['sourceRawAudioBytes'],
        'rawByteEnd': counts()['sourceRawAudioBytes'],
        'cleanByteStart': sourceBefore['sourceCleanAudioBytes'],
        'cleanByteEnd': counts()['sourceCleanAudioBytes'],
        'sourceDelta': sourceDelta,
        'fixtureInjectedBytes': sentBytes,
        'receivedSamples': receivedSamples,
        'receivedRms': rms,
        'inboundBefore': beforeStats,
        'inboundAfter': afterStats,
        'inboundDelta': {
          'audioPacketsReceived': packets,
          'audioSamplesReceived': decoded,
        },
        'deviceBefore': hardwareBefore,
        'deviceAfter': await deviceStats?.call(),
        'pass':
            sentBytes == 48000 * 2 * 6 &&
            receivedSamples >= 48000 * 6 * .7 &&
            rms > 1e-5 &&
            packets > 0 &&
            decoded > 0 &&
            sourceDelta['sourceRawAudioBytes']! >= 48000 * 2 * 6 * .7 &&
            sourceDelta['sourceCleanAudioBytes']! >= 48000 * 2 * 6 * .7 &&
            sourceDelta['sourceVideoFrames']! >= 30 &&
            delta(rawStart)['injectedCleanAudioBytes'] == 0,
      };
    } finally {
      sending = false;
      await bridge.flush();
      if (tapId != null) await MediaTaps.instance.detach(tapId!);
      await sender?.close();
      await receiver?.close();
      await sender?.dispose();
      await receiver?.dispose();
      await aec.stopRender().timeout(const Duration(seconds: 20));
    }
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
          throw StateError('Remote tap attach: $attachmentError');
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
