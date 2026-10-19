import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart';

import 'native_bridge.dart';
import 'capture_native.dart';

import 'package:camera/camera.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.environment['AEC_SDK_MIC_CONTROL'] == '1') {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    final pc = await createPeerConnection({'iceServers': []});
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    await pc.setLocalDescription(await pc.createOffer());
    for (
      var i = 0;
      i < 100 &&
          pc.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final local = (await pc.getLocalDescription())!;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final request = await client.postUrl(
      Uri.parse(
        '${Platform.environment['AEC_PEER'] ?? 'http://127.0.0.1:18796'}/offer',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'session': 'sdk-positive-${Platform.isWindows ? 'win' : 'mac'}',
        'sdp': local.sdp,
        'type': local.type,
      }),
    );
    final response = await request.close();
    final answer = jsonDecode(
      await utf8.decoder.bind(response).join(),
    ) as Map<String, dynamic>;
    await pc.setRemoteDescription(
      RTCSessionDescription(answer['sdp'] as String, answer['type'] as String),
    );
    client.close();
    debugPrint('SDK_MIC_POSITIVE_CONTROL started');
    await Future<void>.delayed(const Duration(seconds: 8));
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await pc.close();
    await pc.dispose();
    await stream.dispose();
    exit(0);
  }
  runApp(const MaterialApp(home: Probe()));
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _Probe();
}

class _Probe extends State<Probe> {
  String status = 'マイクを選んで開始してください', instruction = '';
  int remaining = 0;
  bool started = false;
  List<InputDevice> inputs = [];
  String? inputId;
  double liveDb = -120;
  String inputName = '';
  CameraCapture? activeCamera;
  static const aec = MethodChannel('aec_audio');
  @override
  void initState() {
    super.initState();
    unawaited(loadInputs());
  }

  Future<void> loadInputs() async {
    final discovery = AudioRecorder();
    try {
      final devices = await discovery.listInputDevices();
      if (Platform.environment['AEC_DISCOVER_ONLY'] == '1') {
        final cameras = await availableCameras();
        final report = {
          'microphones': devices
              .map((d) => {'id': d.id, 'label': d.label})
              .toList(),
          'cameras': cameras
              .map((d) => {'name': d.name, 'lens': d.lensDirection.name})
              .toList(),
        };
        File('${Directory.systemTemp.path}/fork_media_devices.json')
            .writeAsStringSync(jsonEncode(report));
        debugPrint('FORK_MEDIA_DEVICES ${jsonEncode(report)}');
        await discovery.dispose();
        exit(0);
      }

      String? wanted = Platform.environment['AEC_MIC_ID'];
      final saved = File('${Directory.systemTemp.path}/native_aec_input.json');
      if (wanted == null && saved.existsSync())
        wanted =
            (jsonDecode(saved.readAsStringSync()) as Map<String, dynamic>)['id']
                as String?;
      final selected =
          devices.where((d) => d.id == wanted).firstOrNull ??
          devices
              .where(
                (d) => Platform.isWindows
                    ? d.label.contains('DualSense')
                    : d.label.contains('MacBook'),
              )
              .firstOrNull ??
          devices.first;
      final explicitChoice =
          Platform.environment['AEC_HUMAN'] == '1' &&
          Platform.environment['AEC_MIC_ID'] == null;
      if (mounted)
        setState(() {
          inputs = devices;
          inputId = explicitChoice ? null : selected.id;
          inputName = explicitChoice ? '未選択' : selected.label;
        });
      if (Platform.environment['AEC_AUTO_START'] != '0') unawaited(run());
    } catch (e) {
      if (mounted) setState(() => status = '入力一覧エラー: $e');
    } finally {
      await discovery.dispose();
    }
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.openUrl(
        method,
        Uri.parse(
          '${Platform.environment['AEC_PEER'] ?? 'http://127.0.0.1:18794'}$path',
        ),
      );
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode != 200)
        throw StateError('peer ${res.statusCode}: $text');
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> run() async {
    if (started || inputId == null) return;
    started = true;
    if (mounted)
      setState(() {
        status = 'カメラとマイクを準備中';
        instruction = 'マイク確認の表示が出てから話してください';
      });
    final human = Platform.environment['AEC_HUMAN'] == '1';
    final session = Platform.environment['AEC_SESSION'] ?? 'physical-auto-1';
    final recorder = AudioRecorder(),
        bridge = CaptureBridge(),
        clock = Stopwatch()..start();
    final raw = BytesBuilder(copy: false),
        near = BytesBuilder(copy: false),
        mixed = BytesBuilder(copy: false);
    final outputs = {'baseline': BytesBuilder(copy: false)};
    final captureGaps = <Map<String, dynamic>>[];
    final selectedOutput = Platform.environment['AEC_OUTPUT'] ?? 'baseline';
    final errors = <String>[],
        phases = <Map<String, dynamic>>[],
        timeline = <Map<String, dynamic>>[];
    StreamSubscription<Uint8List>? sub;
    StreamSubscription<Map<dynamic, dynamic>>? renderSub;
    final camera = CameraCapture();
    bool cameraStarted = false;
    int captureGeneration = 0;
    RTCPeerConnection? pc;
    MediaStream? stream;
    Future<void> chain = Future.value();
    bool send = false, synthNear = false;
    int rawBytes = 0,
        cleanBytes = 0,
        videoFrames = 0,
        injected = 0,
        lastAudio = 0,
        gap = 0,
        videoSent = 0;
    int sampleIndex = 0;
    double rawEnergy = 0;
    int rawSamples = 0;
    Map<String, dynamic>? finalStats, stoppedStats, peerResult;
    String selectedMic = '', selectedSpeaker = '', selectedSpeakerId = '';
    final report = <String, dynamic>{
      'kind': 'normal-native-playout-aec',
      'humanNear': human,
      'syntheticNearInjection': !human,
      'session': session,
      'phases': phases,
      'timeline': timeline,
      'errors': errors,
      'normalNativePlayout': true,
      'selectedOutput': selectedOutput,
      'captureGaps': captureGaps,
      'videoSource': 'camera plugin physical image stream',
      'forkPin': '4477798aa6b47440dc1d6ad5a2d9f9f983bbad87',
      'bridgePin': '8c8ebe2985d6ea31435014df9aa69e191d59c872',
    };
    void mark(String stage) {
      debugPrint('FORK_AEC_STAGE $stage');
      timeline.add({
        'stage': stage,
        'utc': DateTime.now().toUtc().toIso8601String(),
        'clockUs': clock.elapsedMicroseconds,
        'rawBytes': rawBytes,
      });
    }

    Map<String, dynamic> counts() => {
      'rawBytes': rawBytes,
      'cleanBytes': cleanBytes,
      'cameraFrames': videoFrames,
      'cameraSourceFrames': camera.sourceFrames,
      'injectedAudioBytes': injected,
      'injectedVideoFrames': videoSent,
    };
    Future<void> gate(bool enabled) async {
      send = false;
      captureGeneration++;
      await chain;
      await bridge.setSending(enabled);
      send = enabled;
      mark(enabled ? 'send-on' : 'send-off');
    }

    Future<void> phase(
      String name,
      int seconds, {
      bool far = false,
      bool nearSignal = false,
      bool gateOn = true,
      String cue = '',
    }) async {
      synthNear = nearSignal && !human;
      await gate(gateOn);
      final peerStart = await request('POST', '/state', {
        'far': far,
        'phase': name,
      });
      var startEnergy = rawEnergy, startSamples = rawSamples;
      final row = <String, dynamic>{
        'name': name,
        'far': far,
        'nearExpected': nearSignal,
        'start': counts(),
        'peerStart': peerStart,
      };
      mark(name);
      for (var t = seconds; t > 0; t--) {
        if (mounted)
          setState(() {
            status = name;
            instruction = cue;
            remaining = t;
          });
        await Future<void>.delayed(const Duration(seconds: 1));
        if (human && name == 'quiet' && t == 5) {
          startEnergy = rawEnergy;
          startSamples = rawSamples;
          row['levelDiscardSeconds'] = 4;
        }
      }
      await chain;
      row['rawLevelDbfs'] = rawSamples > startSamples
          ? 10 *
                math.log(
                  (rawEnergy - startEnergy) / (rawSamples - startSamples) +
                      1e-24,
                ) /
                math.ln10
          : -120;
      row['end'] = counts();
      row['peerEnd'] = await request('GET', '/stats');
      row['stats'] = await aec.invokeMapMethod<String, dynamic>('stats');
      row['bridgeStats'] = await bridge.stats();
      phases.add(row);
    }

    try {
      if (selectedOutput != 'baseline')
        throw UnsupportedError(
          'This live fixture supports baseline only; replay candidates are offline',
        );
      final bytes = await rootBundle.load('assets/far_speech.pcm');
      final speech = bytes.buffer.asInt16List(
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 2,
      );
      await WebRTC.initialize(
        options: {
          'externalAudioInputOnly':
              Platform.environment['AEC_EXTERNAL_ONLY'] != '0',
        },
      );
      stream = await bridge.create();
      pc = await createPeerConnection({
        'iceServers': [],
        'sdpSemantics': 'unified-plan',
      });
      if (Platform.isWindows) {
        final devices = await navigator.mediaDevices.enumerateDevices();
        final match = Platform.environment['AEC_SPEAKER_MATCH'] ?? 'EDIFIER';
        final speaker = devices.firstWhere(
          (d) => d.kind == 'audiooutput' && d.label.contains(match),
        );
        selectedSpeaker = speaker.label;
        selectedSpeakerId = speaker.deviceId;
        await Helper.selectAudioOutput(speaker.deviceId);
        report['aecStart'] = await aec.invokeMapMethod<String, dynamic>(
          'configure',
          {'deviceId': speaker.deviceId, 'delayMs': 20, 'baselineOnly': true},
        );
      } else {
        selectedSpeaker = 'system default speaker';
        report['aecStart'] = await aec.invokeMapMethod<String, dynamic>(
          'configure',
          {'delayMs': 20},
        );
        renderSub = bridge.renderReference.listen(
          (event) {
            final bytes = event['bytes'] as Uint8List;
            chain = chain
                .then((_) async {
                  await aec.invokeMethod<void>('reverse', {'bytes': bytes});
                })
                .catchError((Object e) {
                  errors.add('$e');
                });
          },
          onError: (Object e) {
            errors.add('reference: $e');
          },
        );
      }
      if (!await recorder.hasPermission())
        throw StateError('microphone permission');
      final input = (await recorder.listInputDevices()).firstWhere(
        (d) => d.id == inputId,
      );
      selectedMic = input.label;
      File(
        '${Directory.systemTemp.path}/native_aec_input.json',
      ).writeAsStringSync(jsonEncode({'id': input.id, 'label': input.label}));
      sub =
          (await recorder.startStream(
            RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: 48000,
              numChannels: 1,
              device: input,
              echoCancel: false,
              autoGain: false,
              noiseSuppress: false,
              streamBufferSize: 480,
            ),
          )).listen((data) {
            final now = clock.elapsedMicroseconds;
            if (lastAudio > 0) {
              gap = math.max(gap, now - lastAudio);
              if (now - lastAudio > 30000)
                captureGaps.add({
                  'rawSample': rawBytes ~/ 2,
                  'gapUs': now - lastAudio,
                  'clockUs': now,
                });
            }
            lastAudio = now;
            rawBytes += data.length;
            raw.add(data);
            double chunkEnergy = 0;
            final measured = ByteData.sublistView(data);
            for (var i = 0; i < data.length ~/ 2; i++) {
              final v = measured.getInt16(i * 2, Endian.little) / 32768;
              chunkEnergy += v * v;
            }
            rawEnergy += chunkEnergy;
            rawSamples += data.length ~/ 2;
            liveDb =
                10 *
                math.log(chunkEnergy / (data.length ~/ 2) + 1e-24) /
                math.ln10;
            final useNear = synthNear;
            final queuedGeneration = captureGeneration;
            final values = ByteData.sublistView(data);
            final inputBytes = Uint8List(data.length),
                knownNear = Uint8List(data.length);
            final inView = ByteData.sublistView(inputBytes),
                nearView = ByteData.sublistView(knownNear);
            for (var i = 0; i < data.length ~/ 2; i++) {
              final position =
                  ((sampleIndex++ * .93 + speech.length / 2).floor()) %
                  speech.length;
              final n = useNear
                  ? (speech[position] *
                            (double.tryParse(
                                  Platform.environment['AEC_NEAR_GAIN'] ?? '',
                                ) ??
                                (2 / 3)))
                        .round()
                  : 0;
              nearView.setInt16(i * 2, n, Endian.little);
              inView.setInt16(
                i * 2,
                (values.getInt16(i * 2, Endian.little) + n).clamp(
                  -32768,
                  32767,
                ),
                Endian.little,
              );
            }
            near.add(knownNear);
            mixed.add(inputBytes);
            chain = chain
                .then((_) async {
                  final result = (await aec.invokeMapMethod<String, dynamic>(
                    'captureCompare',
                    {'bytes': inputBytes},
                  ))!;
                  for (final name in outputs.keys)
                    outputs[name]!.add(result[name] as Uint8List);
                  final clean = result[selectedOutput] as Uint8List;
                  cleanBytes += clean.length;
                  if (send &&
                      queuedGeneration == captureGeneration &&
                      clean.isNotEmpty) {
                    await bridge.pushAudio(clean);
                    injected += clean.length;
                  }
                })
                .catchError((Object e) {
                  errors.add('$e');
                });
          });
      bool vb = false;
      await camera.start((image, w, h, timestamp) {
        videoFrames++;
        if (send && !vb) {
          vb = true;
          bridge
              .pushVideo(image, w, h, timestamp)
              .then((_) {
                videoSent++;
              })
              .catchError((Object e) {
                errors.add('$e');
              })
              .whenComplete(() => vb = false);
        }
      });
      cameraStarted = true;
      activeCamera = camera;
      for (var i = 0; i < 50 && camera.sourceFrames == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (camera.sourceFrames == 0)
        throw StateError('Physical camera produced no frames');
      report['selectedCamera'] = camera.selectedName;
      for (final track in stream.getTracks()) await pc.addTrack(track, stream);
      await pc.setLocalDescription(await pc.createOffer());
      for (
        var i = 0;
        i < 100 &&
            pc.iceGatheringState !=
                RTCIceGatheringState.RTCIceGatheringStateComplete;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final local = (await pc.getLocalDescription())!;
      final answer = await request('POST', '/offer', {
        'session': session,
        'sdp': local.sdp,
        'type': local.type,
      });
      await pc.setRemoteDescription(
        RTCSessionDescription(
          answer['sdp'] as String,
          answer['type'] as String,
        ),
      );
      for (
        var i = 0;
        i < 100 &&
            pc.connectionState !=
                RTCPeerConnectionState.RTCPeerConnectionStateConnected;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (pc.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnected)
        throw StateError('peer not connected');
      if (Platform.environment['AEC_CONTROL'] == '1') {
        await phase(
          'positive-capture-control',
          8,
          gateOn: true,
          cue: 'SDK capture positive control',
        );
      } else {
        if (human)
          await phase(
            'mic-check',
            8,
            nearSignal: true,
            cue: 'マイク確認：「こんにちは、マイクの確認です」と話してください。入力レベルが上がるか見てください',
          );
        if (human) {
          await gate(false);
          if (!mounted)
            throw StateError('UI closed before microphone calibration');
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('次は無音レベルを測ります'),
              content: const Text(
                'ここで話すのを止めてください。コントローラーを動かさず、ボタンを押した後の8秒間は黙ってください。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('声を止めたので、無音を測る'),
                ),
              ],
            ),
          );
        }
        await phase(
          'quiet',
          human ? 8 : 4,
          gateOn: false,
          cue: '8秒間、声を出さずコントローラーも動かさず待ってください',
        );
        if (human) {
          final check =
              (phases.firstWhere(
                        (p) => p['name'] == 'mic-check',
                      )['rawLevelDbfs']
                      as num)
                  .toDouble();
          final quiet =
              (phases.firstWhere((p) => p['name'] == 'quiet')['rawLevelDbfs']
                      as num)
                  .toDouble();
          report['micCheck'] = {
            'speechDbfs': check,
            'quietDbfs': quiet,
            'snrDb': check - quiet,
          };
          if (check - quiet < 6)
            throw StateError(
              '発話と無音のレベル差が6dB未満でした。無音測定中は話さず、周囲の音・コントローラーの操作音も確認してください。',
            );
          if (selectedOutput == 'conditioned') {
            final preflight = await aec.invokeMapMethod<String, dynamic>(
              'stats',
            );
            if ((preflight?['conditionedOverrangeSamples'] as num? ?? 0) > 0)
              throw StateError(
                '入力が低入力向けAECの範囲を超えています。baselineを使用するか、マイクと入力レベルを確認してください。',
              );
          }
        }

        await phase(
          'near-only',
          10,
          nearSignal: true,
          cue: human
              ? '「今日はよい天気です。カメラとマイクは動き続けています。」と繰り返してください'
              : 'capture-only known near speech',
        );
        await phase(
          'far-warmup',
          12,
          far: true,
          gateOn: false,
          cue: '相手の声を聞き、声を出さず待ってください',
        );
        await phase('far-1', 8, far: true, cue: '声を出さず待ってください');
        await phase(
          'doubletalk-1',
          8,
          far: true,
          nearSignal: true,
          cue: human
              ? '相手の声に重ねて「私は今、同時に話しています。声が欠けずに届くか確認します。」と繰り返してください'
              : 'recorded near + physical far echo',
        );
        await phase(
          'doubletalk-gate-off',
          2,
          far: true,
          nearSignal: true,
          gateOn: false,
          cue: human
              ? 'そのまま話し続けてください'
              : 'sender gated, acquisition/DSP continues',
        );
        await phase(
          'doubletalk-2',
          8,
          far: true,
          nearSignal: true,
          cue: human
              ? 'そのまま相手の声に重ねて話し続けてください'
              : 'recorded near + physical far echo',
        );
        await phase('quiet-after', 3, gateOn: false, cue: '声を出さず待ってください');
        await phase('far-2', 6, far: true, cue: '声を出さず待ってください');
        await phase(
          'near-recovery',
          8,
          nearSignal: true,
          cue: human
              ? '最初と同じ「今日はよい天気です。カメラとマイクは動き続けています。」と繰り返してください'
              : 'near recovery',
        );
        await phase('final-quiet', 3, gateOn: false, cue: '終了します');
      }
      report['inboundStats'] = [
        for (final s in await pc.getStats())
          if (s.type == 'inbound-rtp') {'id': s.id, ...s.values},
      ];
      peerResult = await request('POST', '/finish', {});
      finalStats = await aec.invokeMapMethod<String, dynamic>('stats');
    } catch (e, st) {
      errors.add('$e');
      report['stack'] = '$st';
    } finally {
      send = false;
      await camera.dispose();
      await sub?.cancel();
      await renderSub?.cancel();
      await chain;
      await recorder.dispose();
      if (stream != null) {
        report['bridgeStatsBeforeClose'] = await bridge.stats();
        await pc?.close();
        await pc?.dispose();
        await bridge.dispose();
      }
      await aec.invokeMethod<void>('freeze');
      final render = await aec.invokeMethod<Uint8List>('renderTrace');
      final events = await aec.invokeMethod<Uint8List>('dspEvents');
      stoppedStats = await aec.invokeMapMethod<String, dynamic>('dispose');
      final folder = Directory(
        '${Directory.systemTemp.path}/fork_media_aec_$session',
      )..createSync(recursive: true);
      File('${folder.path}/dsp-events.bin')
          .writeAsBytesSync(events ?? Uint8List(0));
      for (final entry in {
        'raw': raw.takeBytes(),
        'near': near.takeBytes(),
        'mixed': mixed.takeBytes(),
        for (final e in outputs.entries) e.key: e.value.takeBytes(),
        'actual_render': render ?? Uint8List(0),
      }.entries) {
        File('${folder.path}/${entry.key}.pcm').writeAsBytesSync(entry.value);
      }
      report.addAll({
        'selectedMic': selectedMic,
        'selectedSpeaker': selectedSpeaker,
        'selectedSpeakerId': selectedSpeakerId,
        'captureStarts': {
          'record': sub == null ? 0 : 1,
          'camera': cameraStarted ? 1 : 0,
        },
        'totals': counts(),
        'maxAudioGapMs': gap / 1000,
        'cameraUniqueSampledFrames': camera.fingerprints.length,
        'finalStats': finalStats,
        'stoppedStats': stoppedStats,
        'peer': peerResult,
        'elapsedMs': clock.elapsedMilliseconds,
        'bridgeStats': await bridge.stats(),
      });
      File('${folder.path}/report.json').writeAsStringSync(jsonEncode(report));
      File('${Directory.systemTemp.path}/fork_media_aec_latest.json')
          .writeAsStringSync(
            jsonEncode({
              'session': session,
              'folder': folder.path,
              'errors': errors,
            }),
          );
      if (mounted)
        setState(() {
          status = errors.isEmpty ? 'DONE' : 'ERROR: $errors';
          instruction = '録音を終了しました';
          remaining = 0;
        });
      if (Platform.environment['AEC_EXIT'] != '0') {
        if (human) await Future<void>.delayed(const Duration(seconds: 5));
        exit(errors.isEmpty ? 0 : 1);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Fork + bridge / physical capture + AEC')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status, style: const TextStyle(fontSize: 30)),
          if (!started && inputs.isNotEmpty)
            DropdownButton<String>(
              isExpanded: true,
              value: inputId,
              hint: const Text('使うマイクを選択してください'),
              items: inputs
                  .map(
                    (d) => DropdownMenuItem(value: d.id, child: Text(d.label)),
                  )
                  .toList(),
              onChanged: (id) {
                if (id != null)
                  setState(() {
                    inputId = id;
                    inputName = inputs.firstWhere((d) => d.id == id).label;
                  });
              },
            ),
          Text(
            '入力: $inputName\nマイクレベル: ${started ? '${liveDb.toStringAsFixed(1)} dBFS' : '未開始（開始後に動きます）'}',
            style: const TextStyle(fontSize: 22),
          ),
          if (activeCamera?.controller != null &&
              activeCamera!.controller!.value.isInitialized)
            SizedBox(
              width: 240,
              height: 135,
              child: CameraPreview(activeCamera!.controller!),
            ),
          Text('$remaining', style: const TextStyle(fontSize: 54)),
          Text(instruction, style: const TextStyle(fontSize: 28)),
          if (!started && inputs.isNotEmpty)
            ElevatedButton(
              onPressed: inputId == null ? null : run,
              child: const Text('開始'),
            ),
        ],
      ),
    ),
  );
}
