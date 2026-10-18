import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart';

import 'local/onnx.dart';
import 'local/dsp/pcm.dart';
import 'local/vad/silero_vad.dart';
import 'local/vad/voice_detector.dart';
import 'local/scd/pyannote_scd.dart';
import 'local/scd/speaker_change_detector.dart';
import 'local/embedding/ecapa.dart';
import 'native_bridge.dart';
import 'wav.dart';

void main() => runApp(
  const MaterialApp(debugShowCheckedModeBanner: false, home: AsrLab()),
);

class AsrLab extends StatefulWidget {
  const AsrLab({super.key});
  @override
  State<AsrLab> createState() => _State();
}

class _State extends State<AsrLab> {
  final bridge = CaptureBridge(), recorder = AudioRecorder();
  final channel = const MethodChannel('external_capture');
  final speakers = <List<Float32List>>[];
  final rows = <Map<String, dynamic>>[];
  final skipped = <Map<String, dynamic>>[];
  final models = <OnnxModel>[];
  VoiceDetector? vad;
  SpeakerChangeDetector? scd;
  EcapaSpeakerEmbedder? embedder;
  MediaStream? stream;
  bool busy = false, capturing = false;
  String status = '待機中';
  int cursor = 0, callbacks = 0;
  Float32List pending = Float32List(0);
  Future<void> vadTail = Future.value(), analysisTail = Future.value();
  int queued = 0, dropped = 0;
  double detectedSeconds = 0;
  int vadVoices = 0;
  bool synthetic = true;
  final errors = <String>[];
  void message(String s) {
    if (mounted) setState(() => status = s);
  }

  Future<String> modelPath(String name) async {
    final data = await rootBundle.load('assets/models/$name');
    final f = File('${Directory.systemTemp.path}/speaker-asr-$name');
    await f.writeAsBytes(data.buffer.asUint8List());
    return f.path;
  }

  Future<void> initialize() async {
    if (vad != null) return;
    message('VAD・話者モデルを準備中');
    final backend = FlutterOnnxBackend(threads: 2);
    for (final name in ['silero_vad.onnx', 'model.onnx', 'ecapa_tdnn.onnx']) {
      models.add(await backend.load(await modelPath(name)));
    }
    vad = VoiceDetector(
      SileroVad(models[0]),
      settings: const VoiceDetectorSettings(
        minSilenceMs: 500,
        voicePadMs: 300,
        maxVoiceMs: 15000,
      ),
    );
    scd = SpeakerChangeDetector(PyannoteScd(models[1]));
    embedder = EcapaSpeakerEmbedder(models[2]);
    stream = await bridge.create();
    await channel.invokeMethod('setOutputEnabled', {'enabled': false});
  }

  void feed(Float32List chunk) {
    callbacks++;
    pending = concatFloat32([pending, chunk]);
    while (pending.length >= 512) {
      final frame = Float32List.fromList(pending.sublist(0, 512));
      pending = Float32List.fromList(pending.sublist(512));
      final timestamp = cursor / 16000;
      cursor += 512;
      vadTail = vadTail.then((_) async {
        final r = await vad!.detect(frame, 16000, timestamp);
        if (r.voice != null) enqueue(r.voice!);
      });
    }
  }

  void enqueue(Voice v) {
    vadVoices++;
    detectedSeconds += v.samples.length / v.sampleRate;
    if (queued >= 12) {
      dropped++;
      errors.add('analysis_queue_full');
      return;
    }
    queued++;
    analysisTail = analysisTail.then((_) async {
      try {
        await analyze(v);
      } catch (e) {
        errors.add(e.runtimeType.toString());
        message('解析エラー: ${e.runtimeType}');
      } finally {
        queued--;
      }
    });
  }

  Future<void> analyze(Voice v) async {
    final parts = await scd!.detect(v.samples, v.sampleRate, v.startTimestamp);
    for (final p in parts) {
      final seconds = p.samples.length / p.sampleRate;
      if (p.kind != 'speaker' || seconds < .5) {
        skipped.add({
          'start': p.startTimestamp,
          'end': p.endTimestamp,
          'reason': p.kind != 'speaker' ? p.kind : 'short',
          'seconds': seconds,
        });
        continue;
      }
      final emb = await embedder!.embed(p.samples, p.sampleRate);
      var best = -1, score = -1.0;
      for (var i = 0; i < speakers.length; i++) {
        for (final e in speakers[i]) {
          final s = cosineSimilarity(emb, e);
          if (s > score) {
            score = s;
            best = i;
          }
        }
      }
      String? speaker;
      if (best >= 0 && (score >= .45 || seconds < 1.5)) {
        speaker = 'speaker-${best + 1}';
        speakers[best].add(emb);
        if (speakers[best].length > 32) speakers[best].removeAt(0);
      } else if (seconds >= 1.5) {
        speakers.add([emb]);
        speaker = 'speaker-${speakers.length}';
      }
      final row = <String, dynamic>{
        'segment_id': 'segment-${rows.length + 1}',
        'speaker_id': speaker,
        'start': p.startTimestamp,
        'end': p.endTimestamp,
        'seconds': seconds,
        'local_scd_index': p.speakerIndex,
        'speaker_similarity': best < 0 ? null : score,
        'text': '',
        'status': 'queued',
      };
      rows.add(row);
      if (mounted) setState(() {});
      await recognize(p, row);
    }
  }

  Future<void> recognize(Speech p, Map<String, dynamic> row) async {
    final id = row['segment_id'];
    message('$id / ${row['speaker_id'] ?? '未確定話者'} を認識中');
    row['status'] = 'connecting';
    final pc = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    WebSocket? ws;
    StreamSubscription<dynamic>? listener;
    String text = '', assistant = '';
    bool done = false;
    int mismatches = 0, turns = 0;
    DateTime? lastDelta;
    final before = Map<String, dynamic>.from(
      await channel.invokeMethod('stats') as Map,
    );
    try {
      for (final track in stream!.getAudioTracks()) {
        await pc.addTrack(track, stream!);
      }
      await pc.createDataChannel('oai-events', RTCDataChannelInit());
      await pc.setLocalDescription(await pc.createOffer());
      var until = DateTime.now().add(const Duration(seconds: 5));
      while (pc.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      ws = await WebSocket.connect(Platform.environment['ASR_LAB_URL']!);
      final answered = Completer<void>();
      listener = ws.listen((raw) async {
        final e = jsonDecode(raw as String);
        if (e['type'] == 'error') {
          if (!answered.isCompleted)
            answered.completeError(StateError(e['text']));
          return;
        }
        if (e['segment_id'] != id) {
          mismatches++;
          return;
        }
        if (e['type'] == 'answer') {
          await pc.setRemoteDescription(
            RTCSessionDescription(e['sdp'], 'answer'),
          );
          if (!answered.isCompleted) answered.complete();
          row['auth'] = e['auth'];
        }
        if (e['type'] == 'unexpected_turn') turns++;
        if (e['type'] == 'transcript') {
          if (e['role'] == 'user') {
            if (e['done'] == true) {
              done = true;
              if (text.isEmpty) text = e['text'] ?? '';
            } else {
              text += e['delta'] ?? '';
            }
            lastDelta = DateTime.now();
            row['text'] = text;
            if (mounted) setState(() {});
          } else if (e['role'] == 'assistant') {
            assistant += e['delta'] ?? e['text'] ?? '';
          }
        }
      });
      ws.add(
        jsonEncode({
          'type': 'start',
          'segment_id': id,
          'sdp': (await pc.getLocalDescription())!.sdp,
        }),
      );
      await answered.future.timeout(const Duration(seconds: 35));
      until = DateTime.now().add(const Duration(seconds: 10));
      while (pc.connectionState !=
              RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (pc.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnected)
        throw StateError('peer_not_connected');
      row['status'] = 'sending';
      await bridge.flush();
      final pcm = resampleLinear(p.samples, p.sampleRate, 48000);
      final clock = Stopwatch()..start();
      for (var i = 0; i < pcm.length; i += 480) {
        final b = Uint8List(960), d = ByteData.sublistView(b);
        for (var j = 0; j < 480 && i + j < pcm.length; j++) {
          d.setInt16(
            j * 2,
            (pcm[i + j] * 32768).round().clamp(-32768, 32767),
            Endian.little,
          );
        }
        await bridge.pushAudio(b);
        final wait = ((i + 480) / 48).round() - clock.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      }
      row['sent_audio_seconds'] = pcm.length / 48000;
      row['status'] = 'waiting';
      final ended = DateTime.now();
      while (DateTime.now().difference(ended).inSeconds < 12) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (lastDelta != null &&
            DateTime.now().difference(ended).inMilliseconds >= 2500 &&
            DateTime.now().difference(lastDelta!).inMilliseconds >= 1800)
          break;
      }
      row['status'] = text.isEmpty
          ? 'no_transcript'
          : done
          ? 'server_done'
          : 'quiescent_provisional';
      row['text'] = text;
      row['server_done'] = done;
      row['wrong_segment_events'] = mismatches;
      row['unexpected_turns'] = turns;
      row['assistant_text_chars'] = assistant.length;
    } catch (e) {
      row['status'] = 'error';
      row['error_type'] = e.runtimeType.toString();
      errors.add(e.runtimeType.toString());
    } finally {
      final after = Map<String, dynamic>.from(
        await channel.invokeMethod('stats') as Map,
      );
      row['output_nonzero_samples'] =
          (after['outputNonzeroSamples'] as num) -
          (before['outputNonzeroSamples'] as num);
      try {
        ws?.add(jsonEncode({'type': 'stop'}));
      } catch (_) {}
      await listener?.cancel();
      await ws?.close();
      await pc.close();
      await bridge.flush();
    }
  }

  Future<void> run(bool fixture) async {
    setState(() => busy = true);
    synthetic = fixture;
    try {
      await initialize();
      vadTail = Future.value();
      analysisTail = Future.value();
      vad!.reset();
      rows.clear();
      skipped.clear();
      speakers.clear();
      errors.clear();
      cursor = 0;
      callbacks = 0;
      pending = Float32List(0);
      vadVoices = 0;
      dropped = 0;
      detectedSeconds = 0;
      if (fixture) {
        message('2人の会話を実時間で解析中');
        final w = Wav.parse(
          (await rootBundle.load('assets/conversation.wav')).buffer
              .asUint8List(),
        );
        final samples = concatFloat32([
          Float32List(32000),
          w.samples,
          Float32List(48000),
        ]);
        final clock = Stopwatch()..start();
        for (var i = 0; i < samples.length; i += 512) {
          feed(
            Float32List.sublistView(samples, i, min(i + 512, samples.length)),
          );
          final wait = ((i + 512) / 16).round() - clock.elapsedMilliseconds;
          if (wait > 0)
            await Future<void>.delayed(Duration(milliseconds: wait));
        }
      } else {
        if (!await recorder.hasPermission())
          throw StateError('microphone_denied');
        message('30秒間、自然に話してください');
        capturing = true;
        final subscription = (await recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
            echoCancel: false,
            noiseSuppress: false,
            autoGain: false,
            audioInterruption: AudioInterruptionMode.none,
          ),
        )).listen((b) => feed(pcm16ToFloat32(b)));
        await Future<void>.delayed(const Duration(seconds: 30));
        await subscription.cancel();
        await recorder.stop();
        capturing = false;
      }
      feed(Float32List(16000));
      await vadTail;
      final v = vad!.flush();
      if (v != null) enqueue(v);
      await analysisTail;
      final report = {
        'kind': 'segmented-chatgpt-asr',
        'synthetic': fixture,
        'capture_callbacks': callbacks,
        'input_seconds': cursor / 16000,
        'vad_voices': vadVoices,
        'vad_seconds': detectedSeconds,
        'speaker_count': speakers.length,
        'skipped': skipped,
        'dropped_voices': dropped,
        'segments': fixture
            ? rows
            : [
                for (final r in rows)
                  {
                    for (final e in r.entries)
                      if (e.key != 'text') e.key: e.value,
                  },
              ],
        'errors': errors,
        'physical_microphone_used': !fixture,
      };
      stdout.writeln('ASR_RESULT ${jsonEncode(report)}');
      message('完了: ${rows.length}区間 / ${speakers.length}話者');
      if (Platform.environment['ASR_AUTOTEST'] == '1') {
        for (final m in models) {
          await m.close();
        }
        exit(0);
      }
    } catch (e) {
      message('エラー: ${e.runtimeType}');
    } finally {
      if (await recorder.isRecording()) await recorder.stop();
      capturing = false;
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (Platform.environment['ASR_AUTOTEST'] == '1')
      WidgetsBinding.instance.addPostFrameCallback((_) => run(true));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('話者区間 × ChatGPT ASR')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'record → Silero VAD → pyannote / ECAPA → 音声区間ごとの ChatGPT ASR',
          ),
          const Text('実マイク試験は30秒。認識対象の音声を OpenAI に送信します。応答音声は再生しません。'),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => run(true),
                child: const Text('共有の2話者素材（マイク不使用）'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: busy ? null : () => run(false),
                child: const Text('実マイクを30秒取得'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(status),
          Expanded(
            child: ListView(
              children: [
                for (final r in rows)
                  ListTile(
                    title: Text(
                      '${r['segment_id']} / ${r['speaker_id'] ?? '話者未確定'} / ${(r['start'] as num).toStringAsFixed(2)}–${(r['end'] as num).toStringAsFixed(2)}秒',
                    ),
                    subtitle: Text('${r['status']}\n${r['text']}'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
