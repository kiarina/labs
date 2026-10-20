import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc_external_media/flutter_webrtc_external_media.dart';
import 'package:record/record.dart';

import 'capture_native.dart';

// Received voice -> playout slot -> application speaker -> AEC reference.
// LAB_PEER=http://... runs the automated fake-peer schedule; LAB_LIVE=ws://...
// connects gpt-live-1-codex through the loopback control server.
String? env(String key) => Platform.environment[key];
const playout = MethodChannel('playout_audio');
const modes = {'passthrough': 0, 'delay': 1, 'pitch': 2};

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: Lab()));
}

class Lab extends StatefulWidget {
  const Lab({super.key});
  @override
  State<Lab> createState() => _LabState();
}

class _LabState extends State<Lab> {
  String status = '準備中', instruction = '', mode = 'passthrough';
  String sendSource = 'post', user = '', voice = '';
  double liveDb = -120;
  int remaining = 0;
  bool started = false, finished = false;
  final List<String> log = [];
  Completer<void>? stopRequest;
  CameraCapture? activeCamera;

  @override
  void initState() {
    super.initState();
    if (env('LAB_AUTO_START') != '0') {
      WidgetsBinding.instance.addPostFrameCallback((_) => run());
    }
  }

  void note(String text) {
    debugPrint('LAB $text');
    if (!mounted) return;
    setState(() {
      status = text;
      log.insert(0, text);
      if (log.length > 14) log.removeLast();
    });
  }

  Future<void> run() async {
    if (started) return;
    started = true;
    final live = env('LAB_LIVE') != null;
    final human = env('LAB_HUMAN') == '1';
    final session = env('LAB_SESSION') ?? (live ? 'mac-live-1' : 'mac-fake-1');
    final clock = Stopwatch()..start();
    final errors = <String>[], timeline = <Map<String, dynamic>>[];
    final phases = <Map<String, dynamic>>[], events = <Map<String, dynamic>>[];
    final recorder = AudioRecorder();
    final camera = CameraCapture();
    final outputs = {
      for (final k in ['raw', 'mixed', 'post', 'pre', 'injected'])
        k: BytesBuilder(copy: false),
    };
    final report = <String, dynamic>{
      'kind': live ? 'gpt-live-1-codex-playout-slot' : 'fake-peer-playout-slot',
      'session': session,
      'human': human,
      'platform': Platform.operatingSystem,
      'forkPin': '4477798aa6b47440dc1d6ad5a2d9f9f983bbad87',
      'bridgePin': '9f5e2da7959094aaf79e90dd12cb56f224eb77e1',
      'timeline': timeline,
      'phases': phases,
      'errors': errors,
    };
    ExternalMediaBridge? bridge;
    RTCPeerConnection? pc;
    WebSocket? socket;
    StreamSubscription<Uint8List>? mic;
    StreamSubscription<Map<dynamic, dynamic>>? nativeReference;
    StreamSubscription<dynamic>? socketSub;
    Future<void> chain = Future.value();
    bool send = false, attached = false, cameraStarted = false;
    int generation = 0, rawBytes = 0, sentBytes = 0, videoFrames = 0;
    int videoSent = 0, lastAudioUs = 0, maxGapUs = 0;
    double nativeRefEnergy = 0;
    int nativeRefSamples = 0;
    // Digital injection queue (synthetic questions or known near speech).
    var injectQueue = Int16List(0);
    var injectPos = 0;
    final transcripts = <Map<String, dynamic>>[];
    int injectedSamples = 0;
    Int16List? nearSpeech;
    bool nearOn = false;
    int nearIndex = 0;

    void mark(String stage, [Map<String, dynamic> extra = const {}]) {
      timeline.add({
        'stage': stage,
        'clockMs': clock.elapsedMilliseconds,
        'rawSample': rawBytes ~/ 2,
        'mode': mode,
        'send': sendSource,
        ...extra,
      });
      note(stage);
    }

    Future<Map<String, dynamic>> stats() async => {
      'playout': await playout.invokeMapMethod<String, dynamic>('stats'),
      'bridge': await bridge?.stats(),
      'rawSamples': rawBytes ~/ 2,
      'sentSamples': sentBytes ~/ 2,
      'cameraSourceFrames': camera.sourceFrames,
      'cameraFrames': videoFrames,
      'videoSent': videoSent,
      'injectedSamples': injectedSamples,
      'nativePlayoutReferenceDbfs': nativeRefSamples == 0
          ? null
          : 10 * math.log(nativeRefEnergy / nativeRefSamples + 1e-24) / math.ln10,
    };

    Future<void> gate(bool on) async {
      send = false;
      generation++;
      await chain;
      await bridge!.setSending(on);
      send = on;
      mark(on ? 'send-on' : 'send-off');
    }

    Future<void> setMode(String name) async {
      mode = name;
      await playout.invokeMethod('setMode', {'mode': modes[name]});
      mark('mode-$name');
    }

    Future<Map<String, dynamic>> peer(String method, String path,
        [Map<String, dynamic>? body]) async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      try {
        final req = await client.openUrl(method, Uri.parse('${env('LAB_PEER')}$path'));
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close();
        final text = await utf8.decoder.bind(res).join();
        if (res.statusCode != 200) throw StateError('peer ${res.statusCode}');
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        client.close();
      }
    }

    void onCapture(Uint8List data) {
      final now = clock.elapsedMicroseconds;
      if (lastAudioUs > 0) maxGapUs = math.max(maxGapUs, now - lastAudioUs);
      lastAudioUs = now;
      rawBytes += data.length;
      outputs['raw']!.add(data);
      final view = ByteData.sublistView(data);
      final n = data.length ~/ 2;
      final mixed = Uint8List(data.length), injected = Uint8List(data.length);
      final mv = ByteData.sublistView(mixed), iv = ByteData.sublistView(injected);
      double energy = 0;
      for (var i = 0; i < n; i++) {
        final v = view.getInt16(i * 2, Endian.little);
        energy += (v / 32768) * (v / 32768);
        var add = 0;
        if (injectPos < injectQueue.length) {
          add = injectQueue[injectPos++];
          injectedSamples++;
        } else if (nearOn && nearSpeech != null) {
          final ns = nearSpeech as Int16List;
          add = (ns[nearIndex++ % ns.length] * .66).round();
          injectedSamples++;
        }
        iv.setInt16(i * 2, add, Endian.little);
        mv.setInt16(i * 2, (v + add).clamp(-32768, 32767), Endian.little);
      }
      liveDb = 10 * math.log(energy / math.max(1, n) + 1e-24) / math.ln10;
      outputs['mixed']!.add(mixed);
      outputs['injected']!.add(injected);
      final queued = generation;
      chain = chain.then((_) async {
        final r = (await playout.invokeMapMethod<String, dynamic>(
            'capture', {'bytes': mixed}))!;
        final post = r['post'] as Uint8List, pre = r['pre'] as Uint8List;
        outputs['post']!.add(post);
        outputs['pre']!.add(pre);
        final chosen = switch (sendSource) {
          'pre' => pre,
          'raw' => mixed.sublist(0, post.length),
          _ => post,
        };
        if (send && queued == generation && chosen.isNotEmpty) {
          await bridge!.addAudio(chosen);
          sentBytes += chosen.length;
        }
      }).catchError((Object e) {
        errors.add('capture: $e');
      });
    }

    Future<void> wait(int seconds, String label) async {
      for (var t = seconds; t > 0; t--) {
        if (mounted) setState(() => remaining = t);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (mounted) setState(() => remaining = 0);
    }

    Future<void> phase(String name, int seconds,
        {bool far = false, bool near = false, bool gateOn = true}) async {
      await gate(gateOn);
      nearOn = near;
      final peerStart = await peer('POST', '/state', {'far': far, 'phase': name});
      final start = await stats();
      mark(name, {'far': far, 'near': near, 'gate': gateOn});
      setState(() => instruction = name);
      await wait(seconds, name);
      await chain;
      phases.add({
        'name': name,
        'far': far,
        'near': near,
        'gate': gateOn,
        'mode': mode,
        'startSample': start['rawSamples'],
        'endSample': rawBytes ~/ 2,
        'start': start,
        'end': await stats(),
        'peerStart': peerStart,
      });
    }

    if (env('LAB_DISCOVER') == '1') {
      final mics = await recorder.listInputDevices();
      final cams = await availableCameras();
      final outs = (await navigator.mediaDevices.enumerateDevices()).where((d) => d.kind == 'audiooutput');
      final found = {
        'microphones': [for (final d in mics) d.label],
        'cameras': [for (final c in cams) c.name],
        'speakers': [for (final d in outs) d.label],
      };
      final outRoot = env('LAB_OUT_DIR') ?? Directory.systemTemp.path;
      File('$outRoot/devices.json').writeAsStringSync(jsonEncode(found));
      exit(0);
    }
    try {
      final speech = await rootBundle.load('assets/far_speech.pcm');
      final ns = speech.buffer.asInt16List(speech.offsetInBytes, speech.lengthInBytes ~/ 2);
      nearSpeech = ns;
      nearIndex = ns.length ~/ 2;
      bridge = await ExternalMediaBridge.create();
      pc = await createPeerConnection({'iceServers': [], 'sdpSemantics': 'unified-plan'});
      String speakerId = '';
      if (Platform.isWindows) {
        final devices = await navigator.mediaDevices.enumerateDevices();
        final match = env('LAB_SPEAKER_MATCH') ?? 'EDIFIER';
        final speaker = devices.firstWhere(
            (d) => d.kind == 'audiooutput' && d.label.contains(match));
        speakerId = speaker.deviceId;
        report['speaker'] = speaker.label;
        // Native playout keeps running on this endpoint (muted mixer gain);
        // the application renders the slot output on the same endpoint.
        await Helper.selectAudioOutput(speaker.deviceId);
      } else {
        report['speaker'] = 'system default output';
        nativeReference = bridge.renderReference.listen((e) {
          final bytes = e['bytes'] as Uint8List;
          final v = ByteData.sublistView(bytes);
          for (var i = 0; i + 1 < bytes.length; i += 2) {
            final s = v.getInt16(i, Endian.little) / 32768;
            nativeRefEnergy += s * s;
          }
          nativeRefSamples += bytes.length ~/ 2;
        });
      }
      report['playoutStart'] = await playout.invokeMapMethod<String, dynamic>(
          'configure', {'delayMs': 20, 'deviceId': speakerId});
      pc.onTrack = (event) {
        if (event.track.kind != 'audio' || attached) return;
        attached = true;
        playout
            .invokeMapMethod<String, dynamic>('attachRemote', {'trackId': event.track.id})
            .then((s) => mark('remote-attached', {'stats': s}))
            .catchError((Object e) {
          errors.add('attach: $e');
        });
      };
      if (!await recorder.hasPermission()) throw StateError('microphone permission');
      final inputs = await recorder.listInputDevices();
      final micMatch = env('LAB_MIC_MATCH') ?? (Platform.isWindows ? 'DualSense' : 'MacBook');
      final input = inputs.where((d) => d.label.contains(micMatch)).firstOrNull ?? inputs.first;
      report['microphone'] = input.label;
      mic = (await recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 48000,
        numChannels: 1,
        device: input,
        echoCancel: false,
        autoGain: false,
        noiseSuppress: false,
        streamBufferSize: 480,
      )))
          .listen(onCapture, onError: (Object e) => errors.add('record: $e'));
      final sendVideo = !live;
      bool videoBusy = false;
      if (env('LAB_CAMERA') != '0') await camera.start((image, w, h, ts) {
        videoFrames++;
        if (send && sendVideo && !videoBusy) {
          videoBusy = true;
          bridge!
              .addVideo(image, width: w, height: h, timestampUs: ts)
              .then((_) {
                videoSent++;
              })
              .catchError((Object e) {
                errors.add('video: $e');
              })
              .whenComplete(() => videoBusy = false);
        }
      });
      if (env('LAB_CAMERA') != '0') {
        cameraStarted = true;
        activeCamera = camera;
        for (var i = 0; i < 50 && camera.sourceFrames == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (camera.sourceFrames == 0) throw StateError('camera produced no frames');
      }
      report['camera'] = camera.selectedName;
      mark('capture-started');

      final stream = bridge.stream;
      for (final t in live ? stream.getAudioTracks() : stream.getTracks()) {
        await pc.addTrack(t, stream);
      }
      if (live) await pc.createDataChannel('oai-events', RTCDataChannelInit());
      await pc.setLocalDescription(await pc.createOffer());
      for (var i = 0;
          i < 100 && pc.iceGatheringState != RTCIceGatheringState.RTCIceGatheringStateComplete;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final offer = (await pc.getLocalDescription())!;

      if (!live) {
        final answer = await peer('POST', '/offer', {'session': session, 'sdp': offer.sdp, 'type': offer.type});
        await pc.setRemoteDescription(RTCSessionDescription(answer['sdp'] as String, answer['type'] as String));
      } else {
        socket = await WebSocket.connect(env('LAB_LIVE')!);
        final answered = Completer<void>();
        socketSub = socket.listen((raw) async {
          final e = jsonDecode(raw as String) as Map<String, dynamic>;
          switch (e['type']) {
            case 'answer':
              await pc!.setRemoteDescription(RTCSessionDescription(e['sdp'] as String, 'answer'));
              if (!answered.isCompleted) answered.complete();
            case 'event':
              events.add({...e, 'clockMs': clock.elapsedMilliseconds, 'rawSample': rawBytes ~/ 2, 'mode': mode, 'send': sendSource});
            case 'user_transcript' || 'voice_transcript':
              final who = e['type'] == 'user_transcript' ? 'user' : 'voice';
              if (!human) transcripts.add({'who': who, 'clockMs': clock.elapsedMilliseconds, 'text': e['text']});
              if (mounted) setState(() => who == 'user' ? user = e['text'] as String : voice = e['text'] as String);
            case 'error':
              errors.add('live: ${e['text']}');
              if (!answered.isCompleted) answered.completeError(StateError('${e['text']}'));
            case 'status':
              note('${e['text']}');
          }
        });
        socket.add(jsonEncode({'type': 'start', 'sdp': offer.sdp}));
        await answered.future.timeout(const Duration(seconds: 40));
      }
      for (var i = 0;
          i < 100 && pc.connectionState != RTCPeerConnectionState.RTCPeerConnectionStateConnected;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (pc.connectionState != RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        throw StateError('peer not connected');
      }
      mark('peer-connected');

      if (!live) {
        await setMode('passthrough');
        await phase('quiet', 3);
        final short = env('LAB_SCHEDULE') == 'short';
        for (final m in short ? ['passthrough'] : ['passthrough', 'delay', 'pitch']) {
          await setMode(m);
          await phase('$m-warmup', 5, far: true);
          await phase('$m-far', 8, far: true);
        }
        if (!short) await phase('pitch-far-gate-off', 3, far: true, gateOn: false);
        if (!short) await phase('pitch-far-gate-on', 4, far: true);
        if (!short) await phase('near-only', 6, near: true);
        if (!short) await phase('pitch-doubletalk', 8, far: true, near: true);
        await phase('final-quiet', 2, gateOn: false);
        report['inboundStats'] = [
          for (final s in await pc.getStats())
            if (s.type == 'inbound-rtp') {'id': s.id, ...s.values},
        ];
        report['peer'] = await peer('POST', '/finish', {});
      } else if (!human) {
        await gate(true);
        await setMode('passthrough');
        await wait(4, 'session settle');
        final plan = [
          ('q1', 'passthrough', 'post'),
          ('q2', 'pitch', 'post'),
          ('q3', 'pitch', 'pre'),
        ];
        for (final (q, m, src) in plan) {
          await setMode(m);
          sendSource = src;
          final pcmData = await rootBundle.load('assets/questions/$q.pcm');
          final samples = pcmData.buffer.asInt16List(pcmData.offsetInBytes, pcmData.lengthInBytes ~/ 2);
          final start = await stats();
          final startEvents = events.length;
          mark('ask-$q', {'questionSamples': samples.length});
          injectQueue = samples;
          injectPos = 0;
          // Window: up to 40 s; ends 6 s after an assistant turn that follows a
          // user turn recognized after this injection began.
          final began = clock.elapsedMilliseconds;
          var lastAssistantDone = -1;
          while (clock.elapsedMilliseconds - began < 40000) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            var userSeen = false, open = 0;
            for (final e in events.skip(startEvents)) {
              if (e['kind'] == 'turn.created' && e['role'] == 'user') userSeen = true;
              if (e['role'] == 'assistant') {
                if (e['kind'] == 'turn.created') open++;
                if (e['kind'] == 'turn.done') {
                  open = math.max(0, open - 1);
                  if (userSeen) lastAssistantDone = e['clockMs'] as int;
                }
              }
            }
            if (open == 0 && lastAssistantDone > 0 && clock.elapsedMilliseconds - lastAssistantDone > 6000) break;
          }
          await chain;
          phases.add({
            'name': 'ask-$q',
            'mode': m,
            'send': src,
            'startSample': start['rawSamples'],
            'endSample': rawBytes ~/ 2,
            'start': start,
            'end': await stats(),
            'events': events.length - startEvents,
          });
        }
      } else {
        // Owner run: speak freely; switch modes on screen; stop when done.
        await gate(true);
        await setMode('passthrough');
        stopRequest = Completer<void>();
        setState(() => instruction = 'スピーカーで話しかけてください。終わったら「終了」');
        await Future.any([stopRequest!.future, Future<void>.delayed(const Duration(minutes: 6))]);
        phases.add({'name': 'owner-conversation', 'startSample': 0, 'endSample': rawBytes ~/ 2});
      }
      report['finalStats'] = await stats();
    } catch (e, st) {
      errors.add('$e');
      report['stack'] = '$st';
    } finally {
      send = false;
      try {
        socket?.add(jsonEncode({'type': 'stop'}));
      } catch (_) {}
      await socketSub?.cancel();
      await socket?.close();
      await mic?.cancel();
      await chain;
      await recorder.dispose();
      if (mounted) setState(() => activeCamera = null);
      if (cameraStarted) await camera.dispose();
      await nativeReference?.cancel();
      report['statsBeforeClose'] = await stats();
      await pc?.close();
      await pc?.dispose();
      final traces = await playout.invokeMapMethod<String, dynamic>('traces') ?? {};
      report['playoutStopped'] = await playout.invokeMapMethod<String, dynamic>('dispose');
      await bridge?.dispose();
      report['events'] = events;
      report['transcripts'] = transcripts;
      report['captureStarts'] = {'record': mic == null ? 0 : 1, 'camera': cameraStarted ? 1 : 0};
      report['maxAudioGapMs'] = maxGapUs / 1000;
      report['elapsedMs'] = clock.elapsedMilliseconds;
      final outRoot = env('LAB_OUT_DIR') ?? Directory.systemTemp.path;
      final folder = Directory('$outRoot/gpt_live_playout_$session')
        ..createSync(recursive: true);
      for (final entry in outputs.entries) {
        File('${folder.path}/${entry.key}.pcm').writeAsBytesSync(entry.value.takeBytes());
      }
      for (final entry in traces.entries) {
        final name = entry.key == 'clockMap' ? 'clock_map.i64' : '${entry.key}.pcm';
        File('${folder.path}/$name').writeAsBytesSync(entry.value as Uint8List);
      }
      File('${folder.path}/report.json').writeAsStringSync(jsonEncode(report));
      File('$outRoot/gpt_live_playout_latest.json')
          .writeAsStringSync(jsonEncode({'session': session, 'folder': folder.path, 'errors': errors}));
      finished = true;
      note(errors.isEmpty ? 'DONE' : 'ERROR: $errors');
      if (env('LAB_EXIT') != '0') exit(errors.isEmpty ? 0 : 1);
    }
  }

  Widget chip(String label, bool on, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(label: Text(label), selected: on, onSelected: (_) => onTap()),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('gpt-live-1-codex / playout slot + AEC')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(status, style: const TextStyle(fontSize: 24)),
            Text('加工: $mode / 送信: $sendSource / マイク ${liveDb.toStringAsFixed(1)} dBFS  $remaining'),
            Text(instruction, style: const TextStyle(fontSize: 20)),
            if (env('LAB_HUMAN') == '1' && started && !finished)
              Row(children: [
                for (final m in modes.keys)
                  chip(m, mode == m, () async {
                    setState(() => mode = m);
                    await playout.invokeMethod('setMode', {'mode': modes[m]});
                  }),
                const SizedBox(width: 16),
                for (final src in ['post', 'pre'])
                  chip(src == 'post' ? '参照: 加工後' : '参照: 加工前（比較）', sendSource == src, () => setState(() => sendSource = src)),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: () => stopRequest?.isCompleted == false ? stopRequest!.complete() : null,
                  child: const Text('終了'),
                ),
              ]),
            if (!started)
              FilledButton(onPressed: run, child: const Text('開始（gpt-live-1-codex に接続）')),
            if (activeCamera?.controller?.value.isInitialized == true)
              SizedBox(width: 200, height: 112, child: CameraPreview(activeCamera!.controller!)),
            const SizedBox(height: 8),
            Text('あなた: $user'),
            Text('音声: $voice'),
            const Divider(),
            for (final l in log) Text(l, style: const TextStyle(fontSize: 12)),
          ]),
        ),
      );
}
