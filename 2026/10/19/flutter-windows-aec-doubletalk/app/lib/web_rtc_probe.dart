import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:aec_audio/aec_audio.dart';
import 'package:record/record.dart';

import 'capture_web.dart';
import 'web_bridge.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_taps/media_taps.dart';

@JS('aecDiagnostics')
external set _diagnostics(JSAny value);
@JS('resultJson')
external set _resultJson(JSString value);
@JS('startAecProbe')
external set _startProbe(JSFunction value);
@JS('installAecCaptureObserver')
external void _installCaptureObserver();
@JS('aecCaptureInfo')
external JSString _captureInfo();

void main() => runApp(const MaterialApp(home: Probe()));

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _Probe();
}

class _Probe extends State<Probe> {
  String status = 'Ready';
  bool running = false;
  String? output;
  @override
  void initState() {
    super.initState();
    _startProbe = (() {
      if (!running) unawaited(run());
    }).toJS;
    if (Uri.base.queryParameters['labtest'] == 'true' &&
        Uri.base.queryParameters['autostart'] == 'true') {
      unawaited(run());
    }
  }

  void log(String value) {
    debugPrint('WEB_RTC_AEC $value');
    if (mounted) setState(() => status = value);
  }

  Future<void> run() async {
    if (running) return;
    setState(() => running = true);
    final labtest = Uri.base.queryParameters['labtest'] == 'true';
    final bridge = CaptureBridge(), farBridge = CaptureBridge();
    _Loopback? farLoop, cleanLoop;
    Timer? tapTimer;
    Future<void> polling = Future.value();
    bool transmit = false;
    int cleanInjectedBytes = 0,
        cleanReceivedBytes = 0,
        farDecodedBytes = 0,
        gateStarts = 0;
    double farDecodedEnergy = 0, cleanDecodedEnergy = 0;
    final gatePhases = <Map<String, dynamic>>[];
    final aec = AecAudio(),
        record = AudioRecorder(),
        camera = createCamera(bridge);
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
    Uint8List actualRender = Uint8List(0);
    Map<String, dynamic> finalStats = {};
    try {
      _installCaptureObserver();
      recordingSource = 'browser-record-raw-pcm';
      final cleanStream = await bridge.create(),
          farStream = await farBridge.create();
      farLoop = await _Loopback.create(farStream);
      cleanLoop = await _Loopback.create(cleanStream);
      await cleanLoop.sender.replaceTrack(null);
      await aec.configure(enabled: true, delayMs: 80);
      tapTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        polling = polling
            .then((_) async {
              for (final tap in await MediaTaps.instance.poll()) {
                final pcm = tap.pcm;
                if (pcm == null) continue;
                final bytes = Uint8List.fromList(
                  Uint8List.view(
                    pcm.buffer,
                    pcm.offsetInBytes,
                    pcm.lengthInBytes,
                  ),
                );
                if (tap.id == farLoop!.tapId) {
                  farDecodedBytes += bytes.length;
                  for (final v in pcm) {
                    farDecodedEnergy += v * v;
                  }
                  await aec.render(bytes);
                } else if (tap.id == cleanLoop!.tapId) {
                  cleanReceivedBytes += bytes.length;
                  for (final v in pcm) {
                    cleanDecodedEnergy += v * v;
                  }
                }
              }
            })
            .catchError((Object e) {
              errors.add('poll: $e');
            });
      });
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
                  if (transmit && out.isNotEmpty) {
                    await bridge.pushAudio(out);
                    cleanInjectedBytes += out.length;
                  }
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
        renders = renders.then((_) => farBridge.pushAudio(bytes)).catchError((
          Object e,
        ) {
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
        final wantedTransmit = spec.$2;
        if (wantedTransmit != transmit) {
          await bridge.flush();
          await cleanLoop.sender.replaceTrack(
            wantedTransmit ? cleanStream.getAudioTracks().first : null,
          );
          transmit = wantedTransmit;
          if (transmit) gateStarts++;
        }
        final gateBefore = {
          'sourceBytes': micBytes,
          'injectedBytes': cleanInjectedBytes,
          'receivedBytes': cleanReceivedBytes,
          'farDecodedBytes': farDecodedBytes,
          'farEnergy': farDecodedEnergy,
          'cleanEnergy': cleanDecodedEnergy,
        };
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
        if (!transmit) await Future<void>.delayed(const Duration(seconds: 1));
        final rtpBefore = await cleanLoop.inboundAudioBytes();
        await Future<void>.delayed(
          Duration(seconds: spec.$3 - (transmit ? 0 : 1)),
        );
        final rtpAfter = await cleanLoop.inboundAudioBytes();
        await captures;
        gatePhases.add({
          'name': spec.$1,
          'transmitting': transmit,
          'receivedRtpBytes': rtpAfter - rtpBefore,
          'rtpDrainMs': transmit ? 0 : 1000,
          'sourceBytes': micBytes - gateBefore['sourceBytes']!,
          'injectedBytes': cleanInjectedBytes - gateBefore['injectedBytes']!,
          'receivedBytes': cleanReceivedBytes - gateBefore['receivedBytes']!,
          'farDecodedBytes': farDecodedBytes - gateBefore['farDecodedBytes']!,
          'farEnergy': farDecodedEnergy - gateBefore['farEnergy']!,
          'cleanEnergy': cleanDecodedEnergy - gateBefore['cleanEnergy']!,
        });
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
      tapTimer?.cancel();
      await renders;
      await polling;
      await sub?.cancel();
      await captures;
      await farLoop?.dispose();
      await cleanLoop?.dispose();
      await farBridge.dispose();
      await record.dispose();
      await camera.dispose();
      await bridge.dispose();
      try {
        actualRender = await aec.renderTrace();
        finalStats = await aec.stats();
      } catch (e) {
        errors.add('trace: $e');
      }
      await aec.dispose();
    }
    final report = {
      'platform': 'web',
      'done': true,
      'rtcFarPath': 'fixture->WebRTC->decodedPCM->AEC.render',
      'rtcCleanPath': 'mic->AEC.clean->send gate->WebRTC->muted decoded tap',
      'cleanMicPlayedToSpeaker': false,
      'gateStarts': gateStarts,
      'farDecodedEnergy': farDecodedEnergy,
      'cleanDecodedEnergy': cleanDecodedEnergy,
      'gatePhases': gatePhases,
      'labtest': labtest,
      'fakeDevices': Uri.base.queryParameters['fake'] == 'true',
      'physicalAcousticValidated': false,
      'recordConfig': {
        'echoCancel': false,
        'noiseSuppress': false,
        'autoGain': false,
      },
      'browserAcquisition': jsonDecode(_captureInfo().toDart),
      'finalStats': finalStats,
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
    report['pass'] =
        errors.isEmpty &&
        phases.length == 8 &&
        farDecodedEnergy > 0 &&
        cleanDecodedEnergy > 0 &&
        gateStarts == 2 &&
        gatePhases.every(
          (p) =>
              p['sourceBytes'] > 0 &&
              p['farDecodedBytes'] > 0 &&
              (p['transmitting']
                  ? p['injectedBytes'] > 0 && p['receivedBytes'] > 0
                  : p['injectedBytes'] == 0 && p['receivedRtpBytes'] == 0),
        ) &&
        phases.every(
          (p) =>
              (p['end'] as Map)['rawByte'] > (p['start'] as Map)['rawByte'] &&
              (p['end'] as Map)['video'] > (p['start'] as Map)['video'],
        );
    if (labtest) {
      _diagnostics = {
        'report': jsonEncode(report),
        'raw': raw.takeBytes().toJS,
        'clean': clean.takeBytes().toJS,
        'reference': reference.takeBytes().toJS,
        'mixed': mixed.takeBytes().toJS,
        'near': near.takeBytes().toJS,
        'actual_render': actualRender.toJS,
      }.jsify()!;
    }
    _resultJson = jsonEncode(report).toJS;
    if (mounted) {
      setState(() {
        status = report['pass'] == true ? 'PASS' : 'FAIL';
        output = const JsonEncoder.withIndent('  ').convert(report);
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Web AEC WebRTC probe')),
    body: SingleChildScrollView(
      child: Column(
        children: [
          ElevatedButton(
            onPressed: running ? null : run,
            child: const Text('Start camera, microphone and speaker probe'),
          ),
          Text(status),
          SelectableText(output ?? ''),
        ],
      ),
    ),
  );
}

class _Loopback {
  final RTCPeerConnection a, b;
  final RTCRtpSender sender;
  final int tapId;
  _Loopback(this.a, this.b, this.sender, this.tapId);
  static Future<_Loopback> create(MediaStream source) async {
    final a = await createPeerConnection({'iceServers': []}),
        b = await createPeerConnection({'iceServers': []});
    final receiver = Completer<MediaStreamTrack>();
    b.onTrack = (e) {
      if (e.track.kind == 'audio' && !receiver.isCompleted) {
        receiver.complete(e.track);
      }
    };
    final sender = await a.addTrack(source.getAudioTracks().first, source);
    await a.setLocalDescription(await a.createOffer());
    await _gather(a);
    await b.setRemoteDescription((await a.getLocalDescription())!);
    await b.setLocalDescription(await b.createAnswer());
    await _gather(b);
    await a.setRemoteDescription((await b.getLocalDescription())!);
    final track = await receiver.future.timeout(const Duration(seconds: 10));
    final tap = await MediaTaps.instance.attach(
      track,
      local: false,
      options: const TapOptions(deliver: true),
    );
    return _Loopback(a, b, sender, tap);
  }

  static Future<void> _gather(RTCPeerConnection pc) async {
    for (var i = 0; i < 50; i++) {
      if (pc.iceGatheringState ==
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('ICE gather');
  }

  Future<int> inboundAudioBytes() async {
    int count = 0;
    for (final s in await b.getStats()) {
      if (s.type == 'inbound-rtp' &&
          (s.values['kind'] == 'audio' || s.values['mediaType'] == 'audio')) {
        count += (s.values['bytesReceived'] as num? ?? 0).toInt();
      }
    }
    return count;
  }

  Future<void> dispose() async {
    await MediaTaps.instance.detach(tapId);
    await a.close();
    await b.close();
    await a.dispose();
    await b.dispose();
  }
}
