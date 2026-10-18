// Windows sender / independent headless Chromium receiver diagnostic.
// Run: flutter build windows --release -t lib/windows_browser_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart';

import 'capture_native.dart';
import 'native_bridge.dart';
import 'platform/platform.dart';

const receiverHtml = r'''<!doctype html><meta charset="utf-8"><title>External input receiver</title><video autoplay muted></video><script>
(async()=>{
 const pc=new RTCPeerConnection({iceServers:[]});const stream=new MediaStream();
 const ctx=new AudioContext(); await ctx.resume();let analyser=null;
 pc.ontrack=e=>{stream.addTrack(e.track);document.querySelector('video').srcObject=stream;
  if(e.track.kind==='audio'){const src=ctx.createMediaStreamSource(new MediaStream([e.track]));const mute=ctx.createGain();mute.gain.value=0;analyser=ctx.createAnalyser();analyser.fftSize=2048;src.connect(analyser).connect(mute).connect(ctx.destination);}
 };
 const offer=await (await fetch('/offer')).json();await pc.setRemoteDescription(offer);
 await pc.setLocalDescription(await pc.createAnswer());
 await new Promise(resolve=>{if(pc.iceGatheringState==='complete')return resolve();pc.addEventListener('icegatheringstatechange',()=>{if(pc.iceGatheringState==='complete')resolve();});});
 await fetch('/answer',{method:'POST',body:JSON.stringify(pc.localDescription)});
 setInterval(async()=>{const stats=await pc.getStats();const result={};for(const s of stats.values())if(s.type==='inbound-rtp')result[s.kind]={...s};
  if(analyser && result.audio){const data=new Float32Array(analyser.fftSize);analyser.getFloatTimeDomainData(data);let ss=0;for(const x of data)ss+=x*x;result.audio.analyserRms=Math.sqrt(ss/data.length);}
  await fetch('/stats',{method:'POST',body:JSON.stringify(result)});
 },100);
})().catch(async e=>fetch('/error',{method:'POST',body:String(e)}));
</script>''';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Text('Windows external input → independent Chromium receiver'),
      ),
    ),
  );
  unawaited(probe());
}

Future<void> probe() async {
  final report = <String, dynamic>{
    'platform': 'windows',
    'receiver': 'independent-chromium',
    'recordingControl':
        Platform.environment['EXTERNAL_CAPTURE_RECORDING_CONTROL'] == '1',
    'synthetic': envValue('synthetic') == 'true',
    'phases': <Object>[],
  };
  final bridge = CaptureBridge();
  final recorder = AudioRecorder();
  final camera = CameraCapture();
  StreamSubscription<Uint8List>? audioSub;
  Timer? timer;
  HttpServer? server;
  Process? chrome;
  Directory? chromeProfile;
  RTCPeerConnection? pc;
  MediaStream? stream;
  var gate = false, vBusy = false, aBusy = false;
  var vf = 0, ab = 0, vi = 0, ai = 0;
  var gapsV = 0, gapsA = 0, lastV = 0, lastA = 0;
  final watch = Stopwatch()..start();
  Map<String, dynamic> stats = {};
  double phaseAudioRmsMax = 0;
  final errors = <String>[];
  void video(Uint8List bytes, int w, int h, int ts) {
    vf++;
    final now = watch.elapsedMilliseconds;
    if (lastV > 0) gapsV = max(gapsV, now - lastV);
    lastV = now;
    if (!gate || vBusy) return;
    vBusy = true;
    bridge
        .pushVideo(bytes, w, h, ts)
        .then((_) {
          vi++;
        })
        .catchError((Object e) {
          errors.add('$e');
        })
        .whenComplete(() => vBusy = false);
  }

  void audio(Uint8List bytes) {
    ab += bytes.length;
    final now = watch.elapsedMilliseconds;
    if (lastA > 0) gapsA = max(gapsA, now - lastA);
    lastA = now;
    if (!gate || aBusy) return;
    aBusy = true;
    bridge
        .pushAudio(bytes)
        .then((_) {
          ai += bytes.length;
        })
        .catchError((Object e) {
          errors.add('$e');
        })
        .whenComplete(() => aBusy = false);
  }

  Map<String, int> counts() => {
    'sourceVideoFrames': vf,
    'sourceAudioBytes': ab,
    'injectedVideoFrames': vi,
    'injectedAudioBytes': ai,
  };
  Future<void> phase(String name, int seconds, bool sending) async {
    await bridge.flush();
    phaseAudioRmsMax = 0;
    gate = sending;
    final before = counts();
    final beforeStats = jsonDecode(jsonEncode(stats)) as Map<String, dynamic>;
    await Future<void>.delayed(Duration(seconds: seconds));
    gate = false;
    while (vBusy || aBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await bridge.flush();
    final after = counts();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final afterStats = jsonDecode(jsonEncode(stats)) as Map<String, dynamic>;
    final delta = {for (final k in before.keys) k: after[k]! - before[k]!};
    num d(String kind, String key) =>
        (afterStats[kind]?[key] as num? ?? 0) -
        (beforeStats[kind]?[key] as num? ?? 0);
    final decodedAudio = d('audio', 'totalSamplesReceived'),
        energy = d('audio', 'totalAudioEnergy'),
        decodedVideo = d('video', 'framesDecoded');
    final pass =
        delta['sourceVideoFrames']! > 0 &&
        delta['sourceAudioBytes']! > 0 &&
        (sending
            ? (decodedAudio > 0 &&
                  d('audio', 'bytesReceived') > 0 &&
                  phaseAudioRmsMax > (report['synthetic'] == true ? 0.05 : 0) &&
                  decodedVideo > 0 &&
                  delta['injectedAudioBytes']! > 0 &&
                  delta['injectedVideoFrames']! > 0)
            : (delta['injectedAudioBytes'] == 0 &&
                  delta['injectedVideoFrames'] == 0));
    (report['phases'] as List).add({
      'name': name,
      ...delta,
      'receiverDelta': {
        'audioSamples': decodedAudio,
        'audioEnergy': energy,
        'audioRmsMax': phaseAudioRmsMax,
        'videoFramesDecoded': decodedVideo,
        'audioBytes': d('audio', 'bytesReceived'),
        'videoBytes': d('video', 'bytesReceived'),
      },
      'beforeStats': beforeStats,
      'afterStats': afterStats,
      'pass': pass,
    });
  }

  try {
    report['sdkSha256'] = await const MethodChannel('external_capture')
        .invokeMethod<String>('recordingSdk');
    stream = await bridge.create();
    pc = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    for (final t in stream.getTracks()) {
      await pc.addTrack(t, stream);
    }
    await pc.setLocalDescription(await pc.createOffer());
    for (
      var n = 0;
      n < 100 &&
          pc.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete;
      n++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final offer = await pc.getLocalDescription();
    final ready = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path == '/offer') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(offer!.toMap()));
      } else if (req.uri.path == '/answer') {
        final a = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        await pc!.setRemoteDescription(
          RTCSessionDescription(a['sdp'] as String, a['type'] as String),
        );
        if (!ready.isCompleted) ready.complete();
      } else if (req.uri.path == '/stats') {
        stats = jsonDecode(
          await utf8.decoder.bind(req).join(),
        ) as Map<String, dynamic>;
        phaseAudioRmsMax = max(
          phaseAudioRmsMax,
          (stats['audio']?['analyserRms'] as num? ?? 0).toDouble(),
        );
      } else if (req.uri.path == '/error') {
        errors.add(await utf8.decoder.bind(req).join());
      } else {
        req.response.headers.contentType = ContentType.html;
        req.response.write(receiverHtml);
      }
      await req.response.close();
    });
    const chromeExe = r'C:\Program Files\Google\Chrome\Application\chrome.exe';
    chromeProfile = await Directory.systemTemp.createTemp(
      'external-capture-chromium-',
    );
    chrome = await Process.start(chromeExe, [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--autoplay-policy=no-user-gesture-required',
      '--user-data-dir=${chromeProfile.path}',
      'http://127.0.0.1:${server.port}/',
    ]);
    unawaited(chrome.stdout.drain<void>());
    unawaited(chrome.stderr.drain<void>());
    await ready.future.timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(seconds: 1));
    final realAudio = envValue('real_audio') == 'true';
    report['realAudio'] = realAudio;
    if (report['synthetic'] == true || realAudio) {
      var tick = 0, sample = 0;
      timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final pcm = ByteData(1920);
        for (var i = 0; i < 960; i++) {
          pcm.setInt16(
            i * 2,
            (sin(2 * pi * 440 * sample++ / 48000) * 8000).round(),
            Endian.little,
          );
        }
        if (report['synthetic'] == true) audio(pcm.buffer.asUint8List());
        if (tick++ % 2 == 0) {
          final f = Uint8List(320 * 240 * 4);
          for (var i = 0; i < f.length; i += 4) {
            f[i] = 40;
            f[i + 1] = (tick % 100) * 2;
            f[i + 2] = 180;
            f[i + 3] = 255;
          }
          video(f, 320, 240, watch.elapsedMicroseconds);
        }
      });
    }
    if (report['synthetic'] != true) {
      if (!await recorder.hasPermission()) {
        throw StateError('Microphone permission denied');
      }
      audioSub = (await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 48000,
          numChannels: 1,
          echoCancel: false,
          noiseSuppress: false,
          autoGain: false,
        ),
      )).listen(audio);
      if (!realAudio) {
        await camera.start(video);
        report['camera'] = camera.selectedName;
      }
    }
    report['sources'] = {
      'video': report['synthetic'] == true || realAudio
          ? 'synthetic-bgra'
          : 'camera',
      'audio': report['synthetic'] == true
          ? 'synthetic-pcm440hz'
          : 'record-microphone',
    };
    report['captureStarts'] = {
      'camera': report['synthetic'] == true || realAudio ? 0 : 1,
      'microphone': report['synthetic'] == true ? 0 : 1,
    };
    await phase('idle-before', 3, false);
    await phase('send-1', 6, true);
    await phase('idle-after-1', 3, false);
    await phase('send-2', 6, true);
    await phase('idle-after-2', 3, false);
    report['totals'] = counts();
    report['maxSourceGapMs'] = {'video': gapsV, 'audio': gapsA};
    report['errors'] = errors;
    report['pass'] =
        (report['phases'] as List).every((dynamic p) => p['pass'] == true) &&
        errors.isEmpty;
  } catch (e, st) {
    report['pass'] = false;
    report['error'] = '$e';
    report['stack'] = '$st';
  } finally {
    timer?.cancel();
    await audioSub?.cancel();
    await recorder.dispose();
    await camera.dispose();
    await pc?.close();
    await pc?.dispose();
    await bridge.dispose();
    await server?.close(force: true);
    chrome?.kill();
    if (chrome != null) {
      try {
        await chrome.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    if (chromeProfile != null) {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await chromeProfile.delete(recursive: true);
      } catch (_) {
        report['temporaryProfileCleanup'] = 'failed';
      }
    }
    try {
      final snapshot = await const MethodChannel('external_capture')
          .invokeMapMethod<String, dynamic>('recordingAudit');
      if (snapshot == null) throw StateError('SDK returned no audit snapshot');
      report['recordingAudit'] = snapshot;
    } catch (e) {
      report['recordingAuditError'] = '$e';
      report['pass'] = false;
    }
  }
  File(
    '${Directory.systemTemp.path}/${envValue('result_name') ?? 'external_browser_result.json'}',
  ).writeAsStringSync(jsonEncode(report));
  exit(0);
}
