import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_taps/media_taps.dart';
import 'package:record/record.dart';

import 'native_bridge.dart';
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

  Future<void> run() async {
    final variant = Platform.environment['UPSTREAM_VARIANT'] ?? 'external';
    final recorder = AudioRecorder(),
        bridge = CaptureBridge(),
        camera = createCamera(Object());
    final clock = Stopwatch()..start(),
        timeline = <Map<String, dynamic>>[],
        errors = <String>[];
    final file = File(
      '${Directory.systemTemp.path}/upstream_input_stages.jsonl',
    );
    file.writeAsStringSync('');
    void mark(String name) {
      final row = {
        'stage': name,
        'pid': pid,
        'utc': DateTime.now().toUtc().toIso8601String(),
        'clockUs': clock.elapsedMicroseconds,
      };
      timeline.add(row);
      file.writeAsStringSync('${jsonEncode(row)}\n', mode: FileMode.append);
      if (mounted) setState(() => status = name);
    }

    StreamSubscription<Uint8List>? sub;
    Timer? timer;
    MediaStream? stream;
    RTCPeerConnection? sender, receiver;
    final taps = <int>[];
    final attach = <Future<void>>[];
    bool inject = false, ab = false, vb = false;
    int rawBytes = 0,
        videoFrames = 0,
        injectedAudio = 0,
        injectedVideo = 0,
        droppedAudio = 0,
        droppedVideo = 0,
        micStarts = 0,
        cameraStarts = 0,
        lastAudio = 0,
        lastVideo = 0,
        gapAudio = 0,
        gapVideo = 0,
        samples = 0;
    double rawSquares = 0;
    final stopWindows = <Map<String, dynamic>>[];
    final phases = <Map<String, dynamic>>[],
        receiverData = <Map<String, dynamic>>[];
    String videoSource = 'not started', selectedMic = 'not started';
    Map<String, int> counts() => {
      'rawBytes': rawBytes,
      'videoFrames': videoFrames,
      'injectedAudio': injectedAudio,
      'injectedVideo': injectedVideo,
    };
    Future<void> hold(String name, int seconds) async {
      mark(name);
      final before = counts();
      if (name.startsWith('idle-after-') && receiver != null &&
          Platform.environment['UPSTREAM_MEASURE_STOPS'] == '1') {
        // Discard one second of decoder/tap backlog, then observe steady off.
        await Future<void>.delayed(const Duration(seconds: 1));
        await MediaTaps.instance.poll();
        final statsBefore = [
          for (final stat in await receiver!.getStats())
            if (stat.type == 'inbound-rtp') {'id': stat.id, ...stat.values},
        ];
        int pcm = 0, frames = 0, nonzero = 0;
        double squares = 0;
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          for (final tap in await MediaTaps.instance.poll()) {
            if (!taps.contains(tap.id)) continue;
            frames += tap.frames.length;
            for (final value in tap.pcm ?? <int>[]) {
              pcm++;
              if (value != 0) nonzero++;
              squares += (value / 32768) * (value / 32768);
            }
          }
        }
        stopWindows.add({
          'name': name, 'settleMs': 1000, 'observeMs': 1000,
          'pcmSamples': pcm, 'nonzeroSamples': nonzero,
          'rms': pcm > 0 ? math.sqrt(squares / pcm) : 0,
          'videoFrames': frames, 'beforeInbound': statsBefore,
          'afterInbound': [
            for (final stat in await receiver!.getStats())
              if (stat.type == 'inbound-rtp') {'id': stat.id, ...stat.values},
          ],
        });
      } else {
        await Future<void>.delayed(Duration(seconds: seconds));
      }
      final after = counts();
      phases.add({
        'name': name,
        'seconds': seconds,
        'before': before,
        'after': after,
        'delta': {for (final k in before.keys) k: after[k]! - before[k]!},
      });
    }

    void audio(Uint8List bytes) {
      final now = clock.elapsedMicroseconds;
      if (lastAudio > 0) gapAudio = math.max(gapAudio, now - lastAudio);
      lastAudio = now;
      rawBytes += bytes.length;
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < bytes.length ~/ 2; i++) {
        final v = data.getInt16(i * 2, Endian.little) / 32768;
        rawSquares += v * v;
        samples++;
      }
      if (!inject) return;
      if (ab) {
        droppedAudio += bytes.length;
        return;
      }
      ab = true;
      bridge
          .pushAudio(bytes)
          .then((_) {
            injectedAudio += bytes.length;
          })
          .catchError((Object e) {
            errors.add('$e');
          })
          .whenComplete(() => ab = false);
    }

    void video(Uint8List bytes, int w, int h, int ts) {
      final now = clock.elapsedMicroseconds;
      if (lastVideo > 0) gapVideo = math.max(gapVideo, now - lastVideo);
      lastVideo = now;
      videoFrames++;
      if (!inject) return;
      if (vb) {
        droppedVideo++;
        return;
      }
      vb = true;
      bridge
          .pushVideo(bytes, w, h, now)
          .then((_) {
            injectedVideo++;
          })
          .catchError((Object e) {
            errors.add('$e');
          })
          .whenComplete(() => vb = false);
    }

    Future<void> exchange() async {
      mark('offer');
      await sender!.setLocalDescription(await sender.createOffer());
      await gather(sender!);
      await receiver!.setRemoteDescription(
        (await sender!.getLocalDescription())!,
      );
      await receiver!.setLocalDescription(await receiver.createAnswer());
      await gather(receiver!);
      await sender!.setRemoteDescription(
        (await receiver!.getLocalDescription())!,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await Future.wait(attach);
    }

    final r = <String, dynamic>{
      'kind': 'candidate-native-external-capture',
      'variant': variant,
      'audioProcessingOff':
          Platform.environment['UPSTREAM_AUDIO_PROCESSING_OFF'] == '1',
      'pid': pid,
      'timeline': timeline,
      'phases': phases,
      'receiver': receiverData,
      'stopWindows': stopWindows,
      'recordingAudit': 'not available in candidate DLL; independent ETW required',
      'additionalCaptureZero': null,
    };
    try {
      mark('begin');
      if (variant != 'native-mic') {
        if (!await recorder.hasPermission()) throw StateError('mic permission');
        final devices = await recorder.listInputDevices();
        final wanted = Platform.environment['UPSTREAM_MIC'] ?? 'DualSense';
        final device = devices.firstWhere(
          (d) => d.label.toLowerCase().contains(wanted.toLowerCase()),
        );
        selectedMic = device.label;
        mark('record-start');
        sub = (await recorder.startStream(
          RecordConfig(
            device: device,
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 48000,
            numChannels: 1,
            echoCancel: false,
            noiseSuppress: false,
            autoGain: false,
            audioInterruption: AudioInterruptionMode.none,
          ),
        )).listen(audio, onError: (Object e) => errors.add('$e'));
        micStarts++;
        if (Platform.environment['UPSTREAM_CAMERA_MODE'] == 'synthetic') {
          videoSource = 'explicit synthetic video; physical camera not tested';
          var tick = 0;
          timer = Timer.periodic(const Duration(milliseconds: 40), (_) {
            final pixels = Uint8List(320 * 240 * 4);
            for (var i = 0; i < pixels.length; i += 4) {
              pixels[i] = 40;
              pixels[i + 1] = tick % 200;
              pixels[i + 2] = 160;
              pixels[i + 3] = 255;
            }
            tick++;
            video(pixels, 320, 240, clock.elapsedMicroseconds);
          });
        } else {
          mark('camera-start');
          await camera.start(video);
          cameraStarts++;
          videoSource = camera.selectedName ?? 'camera';
        }
        await hold('record-only', 4);
      }
      if (variant != 'record-only') {
        mark('before-webRTC-initialize');
        await WebRTC.initialize(options: {
          'externalAudioInputOnly': Platform.environment['UPSTREAM_EXTERNAL_ONLY'] == '1',
        });
        try {
          await const MethodChannel('FlutterWebRTC.Method').invokeMethod<void>('initialize', {
            'options': {'externalAudioInputOnly': Platform.environment['UPSTREAM_EXTERNAL_ONLY'] != '1'},
          });
          throw StateError('Factory policy changed after initialization');
        } on PlatformException catch (e) {
          if (e.code != 'factory_policy_immutable') rethrow;
          r['lateModeChangeRejected'] = true;
        }
        if (variant == 'native-mic') {
          await WebRTC.initialize();
          mark('native-getUserMedia');
          stream = await navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': false,
          });
        } else {
          mark('create-custom-source');
          stream = await bridge.create();
        }
        r['sdkIdentity'] = await const MethodChannel('external_capture')
            .invokeMapMethod<String, dynamic>('candidateIdentity');
        if (Platform.environment['UPSTREAM_SELECT_PLAYOUT'] == '1') {
          r['playoutSelection'] = await const MethodChannel('external_capture')
              .invokeMapMethod<String, dynamic>('selectPlayout');
        }
        await hold('source-only', 3);
        if (variant != 'source-only') {
          mark('create-peer-connections');
          sender = await createPeerConnection({
            'iceServers': [],
            'sdpSemantics': 'unified-plan',
          });
          receiver = await createPeerConnection({
            'iceServers': [],
            'sdpSemantics': 'unified-plan',
          });
          if (Platform.environment['UPSTREAM_DISABLE_NATIVE_PLAYOUT'] == '1') {
            r['nativePlayoutDiagnostic'] = await const MethodChannel('external_capture')
                .invokeMapMethod<String, dynamic>('disableNativePlayoutDiagnostic');
          }
          receiver.onTrack = (event) {
            attach.add(() async {
              if (event.track.kind == 'audio') {
                await Helper.setVolume(
                  double.tryParse(
                        Platform.environment['UPSTREAM_RECEIVER_VOLUME'] ?? '0',
                      ) ??
                      0,
                  event.track,
                );
              }
              taps.add(
                await MediaTaps.instance.attach(
                  event.track,
                  local: false,
                  stream: event.streams.isEmpty ? null : event.streams.first,
                  options: const TapOptions(convertWidth: 160, deliver: true),
                ),
              );
            }());
          };
          RTCRtpTransceiver? special;
          RTCRtpSender? audioSender;
          final audioTrack = stream.getAudioTracks().single;
          if (variant == 'muted' || variant == 'track-gates') {
            audioTrack.enabled = false;
          }
          for (final track in stream.getTracks()) {
            if (track.kind == 'audio' &&
                (variant == 'encoding' ||
                    variant == 'inactive' ||
                    variant == 'sendonly')) {
              final init = RTCRtpTransceiverInit(
                direction: variant == 'inactive'
                    ? TransceiverDirection.Inactive
                    : TransceiverDirection.SendOnly,
                streams: [stream],
                sendEncodings: variant == 'encoding'
                    ? [RTCRtpEncoding(active: false)]
                    : [],
              );
              special = variant == 'inactive'
                  ? await sender.addTransceiver(
                      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
                      init: init,
                    )
                  : await sender.addTransceiver(track: track, init: init);
              audioSender = special.sender;
            } else {
              final value = await sender.addTrack(track, stream);
              if (track.kind == 'audio') audioSender = value;
            }
          }
          audioSender ??= (await sender.getSenders()).firstWhere((s) => s.track?.kind == 'audio');
          await exchange();
          await hold('negotiated-before-external-injection', 2);
          if (variant == 'muted') {
            mark('unmute');
            audioTrack.enabled = true;
          }
          if (variant == 'encoding') {
            mark('activate-encoding');
            final fresh = (await sender.getSenders()).firstWhere(
              (s) => s.track?.kind == 'audio',
            );
            final parameters = fresh.parameters;
            if (parameters.encodings == null || parameters.encodings!.isEmpty) {
              throw StateError('no audio encoding parameters');
            }
            for (final e in parameters.encodings!) {
              e.active = true;
            }
            r['encodingActivationAccepted'] = await fresh.setParameters(
              parameters,
            );
          }
          if (variant == 'inactive') {
            mark('inactive-to-sendonly');
            await audioSender!.replaceTrack(audioTrack);
            await special!.setDirection(TransceiverDirection.SendOnly);
            await exchange();
          }
          for (var cycle = 1; cycle <= 2; cycle++) {
            if (variant == 'replace-gates') {
              mark('native-replace-enable-$cycle');
              await audioSender.replaceTrack(audioTrack);
            }
            if (variant == 'track-gates') {
              mark('native-track-enable-$cycle');
              audioTrack.enabled = true;
            }
            if (variant != 'native-mic') await bridge.flush();
            mark('send-$cycle');
            inject = variant != 'native-mic';
            final before = counts();
            double squares = 0;
            int pcm = 0, frames = 0;
            for (var i = 0; i < 40; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
              for (final tap in await MediaTaps.instance.poll()) {
                if (!taps.contains(tap.id)) continue;
                frames += tap.frames.length;
                final values = tap.pcm;
                if (values != null) {
                  pcm += values.length;
                  for (final v in values) {
                    squares += (v / 32768) * (v / 32768);
                  }
                }
              }
            }
            inject = false;
            while (ab || vb) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            final after = counts();
            final inbound = [
              for (final stat in await receiver.getStats())
                if (stat.type == 'inbound-rtp') {'id': stat.id, ...stat.values},
            ];
            receiverData.add({
              'gate': cycle,
              'pcmSamples': pcm,
              'videoFrames': frames,
              'rms': pcm > 0 ? math.sqrt(squares / pcm) : 0,
              'inbound': inbound,
            });
            phases.add({
              'name': 'send-$cycle',
              'seconds': 4,
              'before': before,
              'after': after,
              'delta': {for (final k in before.keys) k: after[k]! - before[k]!},
            });
            if (variant == 'track-gates') {
              mark('native-track-disable-$cycle');
              audioTrack.enabled = false;
            }
            if (variant == 'replace-gates') {
              mark('native-replace-disable-$cycle');
              await audioSender.replaceTrack(null);
            }
            await hold('idle-after-$cycle', 2);
          }
        }
      }
    } catch (e, st) {
      errors.add('$e');
      r['stack'] = '$st';
    } finally {
      mark('cleanup');
      inject = false;
      timer?.cancel();
      await sub?.cancel();
      while (ab || vb) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await recorder.dispose();
      await camera.dispose();
      for (final id in taps) {
        await MediaTaps.instance.detach(id);
      }
      await sender?.close();
      await receiver?.close();
      await sender?.dispose();
      await receiver?.dispose();
      if (variant == 'native-mic') {
        await stream?.dispose();
      } else if (variant != 'record-only') {
        await bridge.dispose();
      }
      mark('done');
    }
    r.addAll({
      'errors': errors,
      'captureStarts': {'record': micStarts, 'camera': cameraStarts},
      'selectedMicrophone': selectedMic,
      'videoSource': videoSource,
      'totals': counts(),
      'sourceRms': samples > 0 ? math.sqrt(rawSquares / samples) : 0,
      'maxAudioGapMs': gapAudio / 1000,
      'maxVideoGapMs': gapVideo / 1000,
      'busyDroppedAudioBytes': droppedAudio,
      'busyDroppedVideoFrames': droppedVideo,
      'loopbackReceiverVolume':
          double.tryParse(
            Platform.environment['UPSTREAM_RECEIVER_VOLUME'] ?? '0',
          ) ??
          0,
      'functionalTransportPass':
          errors.isEmpty &&
          receiverData.length == 2 &&
          receiverData.every(
            (q) =>
                (q['pcmSamples'] as int) > 0 &&
                (variant == 'native-mic' || (q['videoFrames'] as int) > 0),
          ),
      'scope': 'physical Windows camera is not established by synthetic mode; no AEC/playout-quality claim',
    });
    final result = File(
      '${Directory.systemTemp.path}/upstream_input_result.json',
    );
    result.writeAsStringSync(jsonEncode(r));
    if (mounted) {
      setState(() => status = 'DONE ${errors.isEmpty ? "" : "ERRORS $errors"}');
    }
    if (Platform.environment['UPSTREAM_EXIT'] != 'false') exit(0);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Candidate SDK external capture')),
    body: Text(status),
  );
}

Future<void> gather(RTCPeerConnection pc) async {
  for (var i = 0; i < 50; i++) {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('ICE gathering');
}
