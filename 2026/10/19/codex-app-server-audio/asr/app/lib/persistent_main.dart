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
import 'local/scd/pyannote_scd.dart';
import 'local/scd/speaker_change_detector.dart';
import 'local/embedding/ecapa.dart';
import 'native_bridge.dart';
import 'wav.dart';

void main() => runApp(
  const MaterialApp(debugShowCheckedModeBanner: false, home: PersistentLab()),
);

class PersistentLab extends StatefulWidget {
  const PersistentLab({super.key});
  @override
  State<PersistentLab> createState() => _State();
}

class _State extends State<PersistentLab> {
  static const rate = 16000, hop = 4000, lookahead = 4000, delayMs = 1000;
  final channel = const MethodChannel('external_capture');
  final bridge = CaptureBridge(), recorder = AudioRecorder();
  final models = <OnnxModel>[],
      audio = <double>[],
      vadRanges = <List<int>>[],
      annotations = <Map<String, dynamic>>[],
      ledger = <Map<String, dynamic>>[],
      fragments = <Map<String, dynamic>>[],
      gateTimes = <double>[];
  final clusters = <List<Float32List>>[], errors = <String>[];
  final gates = <int, List<bool>>{};
  final clock = Stopwatch();
  SileroVad? vad;
  SpeakerChangeDetector? scd;
  EcapaSpeakerEmbedder? ecapa;
  MediaStream? stream;
  RTCPeerConnection? pc;
  WebSocket? ws;
  StreamSubscription<dynamic>? messages;
  Timer? pump;
  Future<void> vadTail = Future.value(), gateTail = Future.value();
  bool busy = false, sendBusy = false, synthetic = true, prepared = false;
  int cursor = 0,
      nextHop = hop,
      sendFrame = 0,
      gateLate = 0,
      pumpSkipped = 0,
      sent = 0,
      rejected = 0,
      callbacks = 0,
      assistantChars = 0,
      delegations = 0,
      revisions = 0;
  String status = '待機中';
  double? firstVadMs;
  double deviceOriginMs = 0;
  double? alignmentOffsetMs;
  int? firstDeltaMs;
  Map<String, dynamic>? previousReport;
  void message(String s) {
    if (mounted) setState(() => status = s);
  }

  Future<void> initialize() async {
    if (prepared) return;
    message('ローカルモデルを準備中');
    final backend = FlutterOnnxBackend(threads: 2);
    for (final n in ['silero_vad.onnx', 'model.onnx', 'ecapa_tdnn.onnx']) {
      final b = await rootBundle.load('assets/models/$n');
      final f = File('${Directory.systemTemp.path}/persistent-$n');
      await f.writeAsBytes(b.buffer.asUint8List());
      models.add(await backend.load(f.path));
    }
    vad = SileroVad(models[0]);
    scd = SpeakerChangeDetector(PyannoteScd(models[1]));
    ecapa = EcapaSpeakerEmbedder(models[2]);
    stream = await bridge.create();
    await channel.invokeMethod('setOutputEnabled', {'enabled': false});
    prepared = true;
  }

  void feed(Float32List data) {
    callbacks++;
    audio.addAll(data);
    while (cursor + 512 <= audio.length) {
      final start = cursor;
      cursor += 512;
      final frame = Float32List.fromList(audio.sublist(start, start + 512));
      vadTail = vadTail.then((_) async {
        final prob = await vad!.predict(frame, rate);
        if (prob >= .5) {
          firstVadMs ??= start / 16;
          vadRanges.add([max(0, start - 3200), start + 512 + 3200]);
        }
        while (nextHop + lookahead <= start + 512) {
          final end = nextHop;
          nextHop += hop;
          gateTail = gateTail.then((_) => gate(end));
        }
      });
    }
  }

  Future<void> gate(int end) async {
    final watch = Stopwatch()..start();
    final begin = max(0, end - 96000),
        windowEnd = min(audio.length, end + lookahead);
    final samples = Float32List.fromList(audio.sublist(begin, windowEnd));
    final parts = await scd!.detect(samples, rate, begin / rate);
    final mask = List<bool>.filled(hop ~/ 160, false);
    final fresh = <Map<String, dynamic>>[];
    for (final part in parts) {
      if (part.kind != 'speaker') continue;
      final a = (part.startTimestamp * rate).round(),
          b = (part.endTimestamp * rate).round();
      for (var i = 0; i < mask.length; i++) {
        final t = end - hop + i * 160 + 80;
        if (t >= a && t < b && vadRanges.any((r) => r[0] <= t && t < r[1]))
          mask[i] = true;
      }
      if (b <= end - hop || a >= end) continue;
      final voiced = vadRanges.where((r) => r[1] > a && r[0] < b).toList();
      if (voiced.isEmpty) continue;
      final cropA = max(a, voiced.first[0]), cropB = min(b, voiced.last[1]);
      if ((cropB - cropA) / rate < .6) continue;
      final embedding = await ecapa!.embed(
        Float32List.fromList(audio.sublist(cropA, cropB)),
        rate,
      );
      var best = -1, score = -1.0;
      for (var i = 0; i < clusters.length; i++) {
        for (final v in clusters[i]) {
          final s = cosineSimilarity(embedding, v);
          if (s > score) {
            score = s;
            best = i;
          }
        }
      }
      String? speaker;
      if (best >= 0 && score >= .45) {
        speaker = 'speaker-${best + 1}';
        clusters[best].add(embedding);
        if (clusters[best].length > 32) clusters[best].removeAt(0);
      } else if ((cropB - cropA) / rate >= 1.5) {
        clusters.add([embedding]);
        speaker = 'speaker-${clusters.length}';
      }
      fresh.add({
        'start': cropA / rate,
        'end': cropB / rate,
        'speaker_id': speaker,
        'score': best < 0 ? null : score,
        'available_ms': clock.elapsedMilliseconds,
      });
    }
    gates[(end - hop) ~/ 160] = mask;
    annotations.addAll(fresh);
    gateTimes.add(watch.elapsedMicroseconds / 1000);
    final bytes = Uint8List(hop * 6), data = ByteData.sublistView(bytes);
    for (var i = 0; i < hop * 3; i++) {
      final frame = i ~/ 480;
      if (mask[frame])
        data.setInt16(
          i * 2,
          (audio[end - hop + i ~/ 3] * 32768).round().clamp(-32768, 32767),
          Endian.little,
        );
    }
    final response = await channel.invokeMapMethod<String, dynamic>(
      'scheduleAudio',
      {'bytes': bytes, 'start_frame': (end - hop) ~/ 160},
    );
    final late = (response!['late_prefix_frames'] as num).toInt();
    gateLate += late;
    for (var i = 0; i < mask.length; i++) {
      final frame = (end - hop) ~/ 160 + i;
      final accepted = mask[i] && i >= late;
      ledger.add({
        'device_ms': deviceOriginMs + frame * 10,
        'source_ms': frame * 10,
        'sent': accepted,
      });
      if (accepted) {
        sent += 160;
      } else {
        rejected += 160;
      }
    }
    remap();
    if (mounted) setState(() {});
  }

  void remap() {
    for (final f in fragments) {
      final start = f['start_ms'], end = f['end_ms'];
      if (start is! num || end is! num) {
        f['binding'] = 'missing_timestamps';
        continue;
      }
      if (alignmentOffsetMs == null) {
        f['binding'] = 'clock_pending';
        continue;
      }
      final alignedStart = start + alignmentOffsetMs!,
          alignedEnd = end + alignmentOffsetMs!;
      // The first-voice origin estimate is provisional, not exact word alignment.
      final hits = ledger
          .where(
            (r) =>
                r['sent'] == true &&
                (r['device_ms'] as num) < alignedEnd &&
                (r['device_ms'] as num) + 10 > alignedStart,
          )
          .toList();
      if (hits.isEmpty) {
        f['binding'] = 'no_sent_audio_overlap';
        continue;
      }
      final from = (hits.first['source_ms'] as num) / 1000,
          to = ((hits.last['source_ms'] as num) + 10) / 1000;
      f['source_start'] = from;
      f['source_end'] = to;
      f['display_latency_ms'] = (f['received_ms'] as num) - to * 1000;
      final candidates = <String>{};
      // A 200ms margin makes approximate transcript timing explicit at changes.
      for (var t = from; t <= to + .0001; t += .01) {
        final matching = annotations
            .where(
              (a) =>
                  (a['start'] as num) <= t + .2 &&
                  (a['end'] as num) >= t - .2 &&
                  a['speaker_id'] != null,
            )
            .toList();
        if (matching.isNotEmpty) {
          final newest = matching
              .map((a) => a['available_ms'] as int)
              .reduce(max);
          candidates.addAll(
            matching
                .where((a) => a['available_ms'] == newest)
                .map((a) => a['speaker_id'] as String),
          );
        }
      }
      final old = f['speaker_id'];
      f['speaker_id'] = candidates.length == 1 ? candidates.single : null;
      f['candidates'] = candidates.toList()..sort();
      f['binding'] = candidates.length == 1
          ? 'provisional_timestamp'
          : candidates.isEmpty
          ? 'speaker_pending'
          : 'boundary_ambiguous';
      if (old != null && old != f['speaker_id']) revisions++;
    }
  }

  Future<void> connect() async {
    pc = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    for (final t in stream!.getAudioTracks()) {
      await pc!.addTrack(t, stream!);
    }
    await pc!.createDataChannel('oai-events', RTCDataChannelInit());
    await pc!.setLocalDescription(await pc!.createOffer());
    var deadline = DateTime.now().add(const Duration(seconds: 5));
    while (pc!.iceGatheringState !=
            RTCIceGatheringState.RTCIceGatheringStateComplete &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    ws = await WebSocket.connect(Platform.environment['PERSISTENT_LAB_URL']!);
    final answer = Completer<void>();
    messages = ws!.listen((raw) async {
      final e = jsonDecode(raw as String);
      if (e['type'] == 'answer') {
        await pc!.setRemoteDescription(
          RTCSessionDescription(e['sdp'], 'answer'),
        );
        if (!answer.isCompleted) answer.complete();
      }
      if (e['type'] == 'error') {
        errors.add(e['text']);
        if (!answer.isCompleted)
          answer.completeError(StateError('connection_error'));
      }
      if (e['type'] == 'unexpected_delegation') delegations++;
      if (e['type'] == 'transcript') {
        if (e['role'] == 'assistant') {
          assistantChars += (e['delta'] as String).length;
          return;
        }
        firstDeltaMs ??= clock.elapsedMilliseconds;
        if (alignmentOffsetMs == null &&
            firstVadMs != null &&
            e['start_ms'] is num) {
          final eligible = ledger.where((r) => r['sent'] == true).toList()
            ..sort(
              (a, b) => ((a['source_ms'] as num) - firstVadMs!).abs().compareTo(
                ((b['source_ms'] as num) - firstVadMs!).abs(),
              ),
            );
          if (eligible.isNotEmpty)
            alignmentOffsetMs =
                (eligible.first['device_ms'] as num).toDouble() -
                (e['start_ms'] as num);
        }
        fragments.add({
          'seq': e['seq'],
          'text': e['delta'],
          'start_ms': e['start_ms'],
          'end_ms': e['end_ms'],
          'received_ms': clock.elapsedMilliseconds,
          'speaker_id': null,
        });
        remap();
        if (mounted) setState(() {});
      }
    });
    ws!.add(
      jsonEncode({
        'type': 'start',
        'sdp': (await pc!.getLocalDescription())!.sdp,
      }),
    );
    await answer.future.timeout(const Duration(seconds: 35));
    deadline = DateTime.now().add(const Duration(seconds: 10));
    while (pc!.connectionState !=
            RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (pc!.connectionState !=
        RTCPeerConnectionState.RTCPeerConnectionStateConnected)
      throw StateError('not_connected');
  }

  Future<void> run(bool fixture) async {
    setState(() => busy = true);
    synthetic = fixture;
    StreamSubscription<Uint8List>? capture;
    try {
      await initialize();
      audio.clear();
      vadRanges.clear();
      annotations.clear();
      ledger.clear();
      fragments.clear();
      gateTimes.clear();
      clusters.clear();
      errors.clear();
      gates.clear();
      vad!.reset();
      cursor = 0;
      nextHop = hop;
      sendFrame = 0;
      gateLate = 0;
      pumpSkipped = 0;
      sent = 0;
      rejected = 0;
      callbacks = 0;
      assistantChars = 0;
      delegations = 0;
      revisions = 0;
      firstVadMs = null;
      firstDeltaMs = null;
      alignmentOffsetMs = null;
      vadTail = Future.value();
      gateTail = Future.value();
      if (!fixture && !await recorder.hasPermission())
        throw StateError('microphone_permission');
      message('ChatGPT 接続中（この後の試験中は維持）');
      await connect();
      await bridge.flush();
      final before = Map<String, dynamic>.from(
        await channel.invokeMethod('stats') as Map,
      );
      clock.reset();
      clock.start();
      final timing = await channel.invokeMapMethod<String, dynamic>(
        'beginScheduled',
        {'delay_ms': delayMs},
      );
      deviceOriginMs = (timing!['device_origin_ms'] as num).toDouble();
      if (fixture) {
        message('共有素材をリアルタイム送信中');
        final w = Wav.parse(
          (await rootBundle.load('assets/conversation.wav')).buffer
              .asUint8List(),
        );
        final input = concatFloat32([
          Float32List(rate * 2),
          w.samples,
          Float32List(rate * 3),
        ]);
        for (var i = 0; i < input.length; i += 512) {
          feed(Float32List.sublistView(input, i, min(input.length, i + 512)));
          final wait = ((i + 512) / 16).round() - clock.elapsedMilliseconds;
          if (wait > 0)
            await Future<void>.delayed(Duration(milliseconds: wait));
        }
      } else {
        message('30秒間、交代しながら話してください');
        capture = (await recorder.startStream(
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
        await capture.cancel();
        capture = null;
        await recorder.stop();
      }
      final captureEnd = clock.elapsedMilliseconds;
      feed(Float32List(rate));
      await vadTail;
      await gateTail;
      message('最後の差分を待っています');
      await Future<void>.delayed(const Duration(milliseconds: delayMs + 4000));
      pump?.cancel();
      while (sendBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      remap();
      final after = Map<String, dynamic>.from(
        await channel.invokeMethod('stats') as Map,
      );
      final sourceFrames = audio.length;
      final latencies = [
        for (final f in fragments)
          if (f['display_latency_ms'] is num) f['display_latency_ms'] as num,
      ]..sort();
      final report = {
        'kind': 'persistent-gated-asr',
        'synthetic': fixture,
        'physical_microphone_used': !fixture,
        'connections': 1,
        'capture_callbacks': callbacks,
        'captured_seconds': (sourceFrames - rate) / rate,
        'capture_end_ms': captureEnd,
        'fixed_playout_delay_ms': delayMs,
        'send_clock': 'native_scheduled',
        'clock_origin_method': 'first_vad_to_first_transcript_estimate',
        'alignment_offset_ms': alignmentOffsetMs,
        'device_origin_ms': deviceOriginMs,
        'scheduled_late_frames':
            (after['scheduledLateFrames'] as num) -
            (before['scheduledLateFrames'] as num),
        'scheduled_underflows':
            (after['scheduledUnderflows'] as num) -
            (before['scheduledUnderflows'] as num),
        'first_vad_ms': firstVadMs,
        'first_delta_ms': firstDeltaMs,
        'sent_source_seconds': sent / rate,
        'suppressed_source_seconds': rejected / rate,
        'gate_late_frames': gateLate,
        'pump_skipped_frames': pumpSkipped,
        'gate_ms': gateTimes,
        'speaker_clusters': clusters.length,
        'speaker_revisions': revisions,
        'assistant_text_chars': assistantChars,
        'unexpected_delegations': delegations,
        'output_nonzero_samples':
            (after['outputNonzeroSamples'] as num) -
            (before['outputNonzeroSamples'] as num),
        'audio_dropped_bytes':
            (after['audioDroppedBytes'] as num) -
            (before['audioDroppedBytes'] as num),
        'fragment_count': fragments.length,
        'fragments_during_capture': fragments
            .where((f) => (f['received_ms'] as num) < captureEnd)
            .length,
        'latency_ms_median': latencies.isEmpty
            ? null
            : latencies[latencies.length ~/ 2],
        'latency_ms_p95': latencies.isEmpty
            ? null
            : latencies[min(
                latencies.length - 1,
                (latencies.length * .95).floor(),
              )],
        'fragments': fixture
            ? fragments
            : [
                for (final f in fragments)
                  {
                    for (final e in f.entries)
                      if (e.key != 'text') e.key: e.value,
                  },
              ],
        'speaker_intervals': annotations,
        'send_ledger': ledger,
        'errors': errors,
      };
      previousReport = report;
      stdout.writeln('PERSISTENT_RESULT ${jsonEncode(report)}');
      message('完了：差分${fragments.length}件 / 話者${clusters.length} / 認識中にも文字を表示');
      if (Platform.environment['PERSISTENT_AUTOTEST'] == '1') {
        await close();
        exit(0);
      }
    } catch (e) {
      errors.add(e.runtimeType.toString());
      message('エラー: ${e.runtimeType}');
      if (Platform.environment['PERSISTENT_AUTOTEST'] == '1') {
        stdout.writeln('PERSISTENT_ERROR ${e.runtimeType}');
        await close();
        exit(1);
      }
    } finally {
      pump?.cancel();
      await capture?.cancel();
      if (await recorder.isRecording()) await recorder.stop();
      await close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> close() async {
    try {
      ws?.add(jsonEncode({'type': 'stop'}));
    } catch (_) {}
    await messages?.cancel();
    messages = null;
    await ws?.close();
    ws = null;
    await pc?.close();
    pc = null;
    if (prepared) {
      await channel.invokeMethod('endScheduled');
      await bridge.flush();
    }
  }

  @override
  void initState() {
    super.initState();
    if (Platform.environment['PERSISTENT_AUTOTEST'] == '1')
      WidgetsBinding.instance.addPostFrameCallback((_) => run(true));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('接続維持 × VAD・話者 × ASR')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('接続は1回。先読み1.0秒。差分を先に表示し、音声時刻で話者を暫定更新します。'),
          const Text('実マイクの認識対象音声を OpenAI に送ります。録音・会話文は保存しません。'),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: busy ? null : () => run(false),
                child: const Text('実マイクで30秒試す'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: busy ? null : () => run(true),
                child: const Text('共有素材（マイク不使用）'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(status),
          Container(
            height: 130,
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xfff1f4f9),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                fragments.map((f) => f['text'] as String).join(),
                style: const TextStyle(fontSize: 18, height: 1.5),
              ),
            ),
          ),
          Text(
            '差分 ${fragments.length}件 / 話者 ${clusters.length} / 解析待ちの音声フレーム $gateLate',
          ),
          Expanded(
            child: ListView(
              children: [
                for (final f in fragments.reversed)
                  ListTile(
                    dense: true,
                    title: Text('${f['speaker_id'] ?? '話者保留'}  ${f['text']}'),
                    subtitle: Text(
                      '${f['start_ms']}–${f['end_ms']}ms · ${f['binding'] ?? 'pending'}',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
