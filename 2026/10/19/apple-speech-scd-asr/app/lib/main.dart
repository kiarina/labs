import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'local/onnx.dart';
import 'local/dsp/pcm.dart';
import 'local/vad/silero_vad.dart';
import 'local/vad/voice_detector.dart';
import 'local/scd/pyannote_scd.dart';
import 'local/scd/speaker_change_detector.dart';
import 'local/embedding/ecapa.dart';
import 'speaker_tracker.dart';
import 'wav.dart';
import 'streaming_scd.dart';

void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff25776e),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: const Lab(),
  ),
);

class Lab extends StatefulWidget {
  const Lab({super.key});
  @override
  State<Lab> createState() => _LabState();
}

class _LabState extends State<Lab> {
  final recorder = AudioRecorder();
  final native = const MethodChannel('apple_asr');
  final models = <OnnxModel>[];
  final rows = <Map<String, dynamic>>[];
  final errors = <String>[];
  VoiceDetector? vad;
  SpeakerChangeDetector? scd;
  EcapaSpeakerEmbedder? embedder;
  SpeakerTracker tracker = SpeakerTracker();
  StreamSubscription<Uint8List>? subscription;
  Timer? ticker;
  List<InputDevice> devices = [];
  String? selected;
  bool streaming = Platform.environment['APPLE_SPEAKER_MODE'] != 'baseline';
  StreamingScd? online;
  bool stopping = false;
  bool ready = false,
      running = false,
      busy = false,
      synthetic = false,
      disposing = false;
  String status = 'モデルを準備しています';
  int cursor = 0,
      callbacks = 0,
      frameQueue = 0,
      analysisQueue = 0,
      skipped = 0,
      sequence = 0;
  Float32List pending = Float32List(0);
  Future<void> vadTail = Future.value(), analysisTail = Future.value();
  Stopwatch clock = Stopwatch();
  double level = 0;
  final durations = <double>[];
  @override
  void initState() {
    super.initState();
    unawaited(prepare());
  }

  void update([String? text]) {
    if (text != null) status = text;
    if (mounted && !disposing) setState(() {});
  }

  Future<void> prepare() async {
    try {
      final backend = FlutterOnnxBackend(threads: 2);
      final dir = await Directory.systemTemp.createTemp(
        'apple-speaker-models-',
      );
      for (final name in ['silero_vad.onnx', 'model.onnx', 'ecapa_tdnn.onnx']) {
        final data = await rootBundle.load('assets/models/$name');
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        models.add(await backend.load(file.path));
        await file.delete();
      }
      await dir.delete();
      vad = VoiceDetector(
        SileroVad(models[0]),
        settings: const VoiceDetectorSettings(
          minSilenceMs: 500,
          voicePadMs: 200,
          maxVoiceMs: 6000,
        ),
      );
      scd = SpeakerChangeDetector(PyannoteScd(models[1]));
      embedder = EcapaSpeakerEmbedder(models[2]);
      await native.invokeMethod('prepare').timeout(const Duration(minutes: 3));
      devices = await recorder.listInputDevices();
      ready = true;
      update('準備完了。開始するまでマイクは取得しません。');
      if (Platform.environment['APPLE_SPEAKER_AUTOTEST'] == '1') {
        await start(true);
      }
    } catch (e) {
      errors.add('prepare:${e.runtimeType}');
      update('準備に失敗しました: ${e.runtimeType}');
    }
  }

  Future<void> start(bool fixture) async {
    if (!ready || busy || running || stopping) return;
    busy = true;
    synthetic = fixture;
    try {
      if (!fixture && !await recorder.hasPermission()) {
        update('マイクの使用許可が必要です');
        return;
      }
      vad = VoiceDetector(
        SileroVad(models[0]),
        settings: VoiceDetectorSettings(
          minSilenceMs: 500,
          voicePadMs: 200,
          maxVoiceMs: streaming ? 15000 : 6000,
        ),
      );
      online = StreamingScd(scd!.detect);
      vad!.reset();
      tracker = SpeakerTracker();
      rows.clear();
      errors.clear();
      durations.clear();
      pending = Float32List(0);
      cursor = 0;
      callbacks = 0;
      frameQueue = 0;
      analysisQueue = 0;
      skipped = 0;
      sequence = 0;
      vadTail = Future.value();
      analysisTail = Future.value();
      clock = Stopwatch();
      running = true;
      ticker = Timer.periodic(
        const Duration(milliseconds: 150),
        (_) => update(),
      );
      update(fixture ? '共有音声をリアルタイム再生中' : '取得中。交代するときは少し間を入れてください。');
      if (fixture) {
        final data = await rootBundle.load(
          Platform.environment['APPLE_SPEAKER_FIXTURE'] == 'one_speaker'
              ? 'assets/one-speaker.wav'
              : 'assets/conversation.wav',
        );
        final wav = Wav.parse(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        for (var i = 0; i < wav.samples.length && running; i += 320) {
          feed(
            Float32List.fromList(
              wav.samples.sublist(i, min(i + 320, wav.samples.length)),
            ),
          );
          final target = (min(i + 320, wav.samples.length) / 16000 * 1000000)
              .round();
          final remaining = target - clock.elapsedMicroseconds;
          if (remaining > 0)
            await Future<void>.delayed(Duration(microseconds: remaining));
        }
        await stop();
        if (Platform.environment['APPLE_SPEAKER_AUTOTEST'] == '1') {
          stdout.writeln(
            jsonEncode({
              'type': 'apple_speaker_fixture',
              'mode': streaming ? 'streaming' : 'baseline',
              'scd_inferences': online?.inferences,
              'scd_inference_ms': online?.inferenceMs,
              'fixture_variant':
                  Platform.environment['APPLE_SPEAKER_FIXTURE'] ??
                  'conversation',
              'rows': rows
                  .map(
                    (r) => {
                      'id': r['id'],
                      'speaker_id': speaker(r),
                      'start': r['start'],
                      'end': r['end'],
                      'asr_ms': r['asr_ms'],
                      'end_to_text_ms': r['end_to_text_ms'],
                      'status': r['status'],
                      'characters': (r['text'] as String).length,
                      'text': r['text'],
                      'confirmed_ms': r['confirmed_ms'],
                      'reason': r['reason'],
                    },
                  )
                  .toList(),
              'callbacks': callbacks,
              'source_seconds': cursor / 16000,
              'speakers': tracker.speakers.length,
              'errors': errors,
              'skipped': skipped,
              'microphone_used': false,
            }),
          );
          await closeModels();
          exit(errors.isEmpty && rows.isNotEmpty ? 0 : 1);
        }
      } else {
        final device = devices.where((d) => d.id == selected).firstOrNull;
        final stream = await recorder.startStream(
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
            device: device,
            echoCancel: false,
            noiseSuppress: false,
            autoGain: false,
          ),
        );
        subscription = stream.listen(
          (bytes) {
            final view = ByteData.sublistView(bytes);
            feed(
              Float32List.fromList(
                List.generate(
                  bytes.length ~/ 2,
                  (i) => view.getInt16(i * 2, Endian.little) / 32768,
                ),
              ),
            );
          },
          onError: (Object e) {
            fail('capture:${e.runtimeType}');
          },
        );
      }
    } catch (e) {
      fail('start:${e.runtimeType}');
    } finally {
      busy = false;
      update();
    }
  }

  void fail(String error) {
    if (!errors.contains(error)) errors.add(error);
    update('エラー: $error');
    if (running) unawaited(stop());
  }

  void feed(Float32List samples) {
    if (!running) return;
    if (callbacks == 0) clock.start();
    callbacks++;
    var sum = 0.0;
    for (final v in samples) {
      sum += v * v;
    }
    level = samples.isEmpty ? 0 : sqrt(sum / samples.length);
    pending = concatFloat32([pending, samples]);
    while (pending.length >= 512) {
      if (frameQueue >= 128) {
        fail('vad_queue_full');
        return;
      }
      final frame = Float32List.fromList(pending.sublist(0, 512));
      pending = Float32List.fromList(pending.sublist(512));
      final at = cursor / 16000;
      cursor += 512;
      frameQueue++;
      vadTail = vadTail.then((_) async {
        try {
          final result = await vad!.detect(frame, 16000, at);
          if (streaming) {
            final parts = await online!.feed(
              frame,
              at,
              result.isVoice,
              endpoint: result.voice?.endTimestamp,
            );
            for (final part in parts) {
              enqueueConfirmed(part);
            }
          } else if (result.voice != null) {
            enqueue(result.voice!);
          }
        } catch (e) {
          fail('vad:${e.runtimeType}');
        } finally {
          frameQueue--;
        }
      });
    }
  }

  void enqueue(Voice voice) {
    if (analysisQueue >= 12) {
      fail('analysis_queue_full');
      return;
    }
    analysisQueue++;
    analysisTail = analysisTail.then((_) async {
      try {
        await analyze(voice);
      } catch (e) {
        fail('analysis:${e.runtimeType}');
      } finally {
        analysisQueue--;
        update();
      }
    });
  }

  Uint8List pcmBytes(Float32List samples) {
    final out = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      out.setInt16(
        i * 2,
        (samples[i] * 32768).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
    return out.buffer.asUint8List();
  }

  String speaker(Map<String, dynamic> row) {
    final o = row['observation'] as SpeakerObservation?;
    return o?.speaker == null ? '話者未確定' : 'speaker-${o!.speaker! + 1}';
  }

  Future<void> analyze(Voice voice) async {
    final parts = await scd!.detect(
      voice.samples,
      voice.sampleRate,
      voice.startTimestamp,
    );
    for (final part in parts) {
      await processPart(part, clock.elapsedMicroseconds / 1000, 'batch');
    }
  }

  void enqueueConfirmed(ConfirmedPart part) {
    if (analysisQueue >= 12) {
      fail('analysis_queue_full');
      return;
    }
    analysisQueue++;
    final confirmedMs = clock.elapsedMicroseconds / 1000;
    analysisTail = analysisTail.then((_) async {
      try {
        await processPart(part.speech, confirmedMs, part.reason);
      } catch (e) {
        fail('analysis:${e.runtimeType}');
      } finally {
        analysisQueue--;
        update();
      }
    });
  }

  Future<void> processPart(Speech part, double scdStart, String reason) async {
    if (part.kind != 'speaker' || part.samples.length / part.sampleRate < .5) {
      skipped++;
      return;
    }
    final vector = await embedder!.embed(part.samples, part.sampleRate);
    final observation = tracker.observe(
      vector,
      part.startTimestamp,
      part.endTimestamp,
    );
    if (tracker.speakers.length > 16) {
      fail('speaker_limit');
      return;
    }
    final id = 'segment-${++sequence}';
    final row = <String, dynamic>{
      'id': id,
      'observation': observation,
      'start': part.startTimestamp,
      'end': part.endTimestamp,
      'text': '',
      'status': '文字起こし中',
      'asr_ms': null,
      'end_to_text_ms': null,
      'segmentation_ms': clock.elapsedMicroseconds / 1000 - scdStart,
      'reason': reason,
      'confirmed_ms': scdStart,
    };
    rows.add(row);
    if (rows.length > 200) rows.removeAt(0);
    update();
    final watch = Stopwatch()..start();
    try {
      final sentSpeaker = speaker(row);
      final response = Map<String, dynamic>.from(
        await native
                .invokeMethod('recognize', {
                  'id': id,
                  'speaker_id': sentSpeaker,
                  'audio': pcmBytes(part.samples),
                })
                .timeout(const Duration(seconds: 20))
            as Map,
      );
      if (response['id'] != id || response['speaker_id'] != sentSpeaker)
        throw StateError('request_binding_mismatch');
      row['text'] = response['text'] as String;
      row['status'] = (row['text'] as String).isEmpty ? '認識結果なし' : '確定';
      row['asr_ms'] = watch.elapsedMicroseconds / 1000;
      row['end_to_text_ms'] =
          clock.elapsedMicroseconds / 1000 - part.endTimestamp * 1000;
      durations.add(row['asr_ms'] as double);
    } catch (e) {
      row['status'] = '認識失敗';
      errors.add('asr:${e.runtimeType}');
    }
    update();
  }

  Future<void> stop() async {
    if (!running) return;
    running = false;
    stopping = true;
    busy = true;
    update('停止して残りの区間を確定しています');
    if (!synthetic) {
      await recorder.stop();
      await subscription?.cancel();
      subscription = null;
    }
    await vadTail;
    if (pending.isNotEmpty) {
      final frame = Float32List(512)..setRange(0, pending.length, pending);
      final remainderAt = cursor / 16000;
      final last = await vad!.detect(frame, 16000, remainderAt);
      cursor += pending.length;
      pending = Float32List(0);
      if (streaming) {
        for (final part in await online!.feed(
          frame,
          remainderAt,
          last.isVoice,
          endpoint: last.voice?.endTimestamp,
        )) {
          enqueueConfirmed(part);
        }
      } else if (last.voice != null) {
        enqueue(last.voice!);
      }
    }
    final remainder = vad!.flush();
    if (streaming) {
      for (final part in online!.finish()) {
        enqueueConfirmed(part);
      }
    } else if (remainder != null) {
      enqueue(remainder);
    }
    await analysisTail;
    ticker?.cancel();
    ticker = null;
    clock.stop();
    busy = false;
    stopping = false;
    level = 0;
    update(
      errors.isEmpty
          ? '完了。内容と話者ID、速さを確認してください。'
          : '完了（${errors.length}件のエラー）。画面の結果を確認してください。',
    );
  }

  Future<void> closeModels() async {
    for (final model in models) {
      await model.close();
    }
    models.clear();
  }

  @override
  void dispose() {
    disposing = true;
    ticker?.cancel();
    unawaited(subscription?.cancel() ?? Future.value());
    unawaited(recorder.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final average = durations.isEmpty
        ? null
        : durations.reduce((a, b) => a + b) / durations.length;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Apple Speaker Lab',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text('record → VAD・SCD → SpeechAnalyzer　｜　すべて端末内で処理'),
              SwitchListTile(
                title: const Text('話者変化で早期確定（逐次SCD）'),
                value: streaming,
                onChanged: running || busy || stopping
                    ? null
                    : (v) => setState(() => streaming = v),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: ready && !running && !busy && !stopping
                        ? () => start(false)
                        : null,
                    icon: const Icon(Icons.mic),
                    label: const Text('実マイクを開始'),
                  ),
                  OutlinedButton.icon(
                    onPressed: running ? stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止して確定'),
                  ),
                  OutlinedButton(
                    onPressed: ready && !running && !busy && !stopping
                        ? () => start(true)
                        : null,
                    child: const Text('共有音声で試す'),
                  ),
                  SizedBox(
                    width: 300,
                    child: DropdownButtonFormField<String>(
                      initialValue: selected ?? '',
                      decoration: const InputDecoration(labelText: '入力マイク'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('OSの既定マイク'),
                        ),
                        for (final d in devices)
                          DropdownMenuItem(
                            value: d.id,
                            child: Text(
                              d.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: running
                          ? null
                          : (v) => setState(() => selected = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(status, style: const TextStyle(fontSize: 17)),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: (level * 8).clamp(0, 1)),
              const SizedBox(height: 8),
              Text(
                '${(cursor / 16000).toStringAsFixed(1)}秒 / ${rows.length}区間 / ${tracker.speakers.length}話者候補　解析待ち $analysisQueue　ASR平均 ${average?.toStringAsFixed(0) ?? "—"}ms',
              ),
              const SizedBox(height: 8),
              Text(
                streaming
                    ? '話者変化を逐次検出し、境界が安定した左区間から文字起こしします。無音500ms・1人の連続発話15秒は補助の区切りです。短い声は未確定になり、録音・会話文は保存しません。'
                    : '無音500msまたは最大6秒で区切ってから解析する比較用の初版です。録音・会話文は保存しません。',
                style: TextStyle(color: Colors.white70),
              ),
              const Divider(height: 24),
              Expanded(
                child: rows.isEmpty
                    ? const Center(
                        child: Text(
                          '開始して自然に話してください。2人なら交代時に少し間を入れ、同じ方がもう一度話すとIDの再登場も確認できます。',
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final r = rows[rows.length - 1 - index];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${speaker(r)}　${(r['start'] as double).toStringAsFixed(2)}–${(r['end'] as double).toStringAsFixed(2)}秒　${r['id']}',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SelectableText(
                                    (r['text'] as String).isEmpty
                                        ? r['status'] as String
                                        : r['text'] as String,
                                    style: const TextStyle(fontSize: 21),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${r['status']}　ASR ${r['asr_ms']?.toStringAsFixed(0) ?? "—"}ms　音声区間末尾→表示 ${r['end_to_text_ms']?.toStringAsFixed(0) ?? "—"}ms',
                                    style: const TextStyle(
                                      color: Colors.white60,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
