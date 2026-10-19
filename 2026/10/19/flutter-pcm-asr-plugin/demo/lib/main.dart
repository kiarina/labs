// Microphone -> Silero VAD -> streaming pyannote SCD -> ECAPA speaker ID ->
// pcm_asr (the OS speech engine), on iOS, Android, Web and macOS.
//
// Copied from the Mac-only lab app `2026/10/19/apple-speech-scd-asr/app`
// (record, VAD, streaming SCD, speaker tracker, UI) with the native
// `apple_asr` channel replaced by the pcm_asr plugin, dart:io removed from
// the UI, and the ONNX models loaded per platform.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pcm_asr/pcm_asr.dart';
import 'package:record/record.dart';

import 'local/dsp/pcm.dart';
import 'local/embedding/ecapa.dart';
import 'local/onnx.dart';
import 'local/scd/pyannote_scd.dart';
import 'local/scd/speaker_change_detector.dart';
import 'local/vad/silero_vad.dart';
import 'local/vad/voice_detector.dart';
import 'model_loader_io.dart' if (dart.library.js_interop) 'model_loader_web.dart';
import 'speaker_tracker.dart';
import 'streaming_scd.dart';
import 'wav.dart';

/// `--dart-define=PCM_ASR_DEMO_AUTOTEST=1`: play the shared conversation at
/// real time on start, print one `PCM_ASR_DEMO {json}` line, exit on desktop.
const autotest = String.fromEnvironment('PCM_ASR_DEMO_AUTOTEST') == '1';
const locale = String.fromEnvironment('PCM_ASR_LOCALE', defaultValue: 'ja-JP');

void main() => runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff25776e), brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: const Demo(),
      ),
    );

class Demo extends StatefulWidget {
  const Demo({super.key});
  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  final recorder = AudioRecorder();
  final asr = const PcmAsr();
  final models = <OnnxModel>[];
  final rows = <Map<String, dynamic>>[];
  final errors = <String>[];
  RecognitionSupport? support;
  VoiceDetector? vad;
  SpeakerChangeDetector? scd;
  EcapaSpeakerEmbedder? embedder;
  SpeakerTracker tracker = SpeakerTracker();
  StreamSubscription<Uint8List>? subscription;
  Timer? ticker;
  List<InputDevice> devices = [];
  String? selected;
  bool streaming = true;
  StreamingScd? online;
  bool stopping = false;
  bool ready = false, running = false, busy = false, synthetic = false, disposing = false;
  String status = 'モデルを準備しています';
  int cursor = 0, callbacks = 0, frameQueue = 0, analysisQueue = 0, skipped = 0, sequence = 0;
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

  void log(String kind, Map<String, Object?> data) {
    // ignore: avoid_print
    print('PCM_ASR_DEMO ${jsonEncode({'kind': kind, ...data})}');
  }

  Future<void> prepare() async {
    try {
      final backend = makeBackend();
      for (final name in ['silero_vad.onnx', 'model.onnx', 'ecapa_tdnn.onnx']) {
        update('モデルを準備しています: $name');
        models.add(await loadModelAsset(backend, name));
      }
      vad = VoiceDetector(SileroVad(models[0]), settings: const VoiceDetectorSettings(minSilenceMs: 500, voicePadMs: 200, maxVoiceMs: 6000));
      scd = SpeakerChangeDetector(PyannoteScd(models[1]));
      embedder = EcapaSpeakerEmbedder(models[2]);
      update('音声認識を準備しています');
      support = await asr.support(locale: locale);
      log('support', support!.toJson());
      if (!support!.supported) {
        update('この端末では $locale の音声認識が使えません: ${support!.reason}');
        return;
      }
      final t = DateTime.now();
      await asr.prepare(locale: locale).timeout(const Duration(minutes: 3));
      log('prepare', {'ms': DateTime.now().difference(t).inMilliseconds});
      try {
        devices = await recorder.listInputDevices();
      } catch (_) {
        devices = [];
      }
      ready = true;
      update('準備完了。開始するまでマイクは取得しません。');
      if (autotest) await start(true);
    } catch (e) {
      errors.add('prepare:${e.runtimeType}');
      log('fatal', {'error': e.toString()});
      update('準備に失敗しました: $e');
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
        settings: VoiceDetectorSettings(minSilenceMs: 500, voicePadMs: 200, maxVoiceMs: streaming ? 15000 : 6000),
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
      ticker = Timer.periodic(const Duration(milliseconds: 150), (_) => update());
      update(fixture ? '共有音声をリアルタイム再生中' : '取得中。交代するときは少し間を入れてください。');
      if (fixture) {
        final data = await rootBundle.load('assets/conversation.wav');
        final wav = Wav.parse(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        for (var i = 0; i < wav.samples.length && running; i += 320) {
          feed(Float32List.fromList(wav.samples.sublist(i, min(i + 320, wav.samples.length))));
          final target = (min(i + 320, wav.samples.length) / 16000 * 1000000).round();
          final remaining = target - clock.elapsedMicroseconds;
          if (remaining > 0) await Future<void>.delayed(Duration(microseconds: remaining));
        }
        await stop();
        if (autotest) {
          log('fixture', {
            'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
            'engine': support?.engine,
            'on_device': support?.onDevice,
            'rows': [
              for (final r in rows)
                {
                  'id': r['id'],
                  'speaker_id': speaker(r),
                  'start': r['start'],
                  'end': r['end'],
                  'asr_ms': r['asr_ms'],
                  'end_to_text_ms': r['end_to_text_ms'],
                  'status': r['status'],
                  'text': r['text'],
                  'reason': r['reason'],
                }
            ],
            'speakers': tracker.speakers.length,
            'errors': errors,
            'skipped': skipped,
            'scd_inferences': online?.inferences,
          });
          log('done', {'ok': errors.isEmpty && rows.isNotEmpty});
          await closeModels();
          if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            SystemNavigator.pop();
          }
        }
      } else {
        final device = devices.where((d) => d.id == selected).firstOrNull;
        final stream = await recorder.startStream(RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          device: device,
          echoCancel: false,
          noiseSuppress: false,
          autoGain: false,
        ));
        subscription = stream.listen(
          (bytes) {
            final view = ByteData.sublistView(bytes);
            feed(Float32List.fromList(List.generate(bytes.length ~/ 2, (i) => view.getInt16(i * 2, Endian.little) / 32768)));
          },
          onError: (Object e) => fail('capture:${e.runtimeType}'),
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
            final parts = await online!.feed(frame, at, result.isVoice, endpoint: result.voice?.endTimestamp);
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
      out.setInt16(i * 2, (samples[i] * 32768).round().clamp(-32768, 32767), Endian.little);
    }
    return out.buffer.asUint8List();
  }

  String speaker(Map<String, dynamic> row) {
    final o = row['observation'] as SpeakerObservation?;
    return o?.speaker == null ? '話者未確定' : 'speaker-${o!.speaker! + 1}';
  }

  Future<void> analyze(Voice voice) async {
    final parts = await scd!.detect(voice.samples, voice.sampleRate, voice.startTimestamp);
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
    final observation = tracker.observe(vector, part.startTimestamp, part.endTimestamp);
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
      final result = await asr.transcribe(TranscribeRequest(
        id: id,
        locale: locale,
        audio: PcmSegment(pcm16le: pcmBytes(part.samples), sampleRate: part.sampleRate),
        timeout: const Duration(seconds: 20),
      ));
      if (result.id != id) throw StateError('request_binding_mismatch');
      row['text'] = result.text;
      row['status'] = result.text.isEmpty ? '認識結果なし' : '確定';
      row['asr_ms'] = watch.elapsedMicroseconds / 1000;
      row['end_to_text_ms'] = clock.elapsedMicroseconds / 1000 - part.endTimestamp * 1000;
      durations.add(row['asr_ms'] as double);
    } on PcmAsrException catch (e) {
      row['status'] = '認識失敗: ${e.code.name}';
      errors.add('asr:${e.code.name}');
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
        for (final part in await online!.feed(frame, remainderAt, last.isVoice, endpoint: last.voice?.endTimestamp)) {
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
    update(errors.isEmpty ? '完了。内容と話者ID、速さを確認してください。' : '完了（${errors.length}件のエラー）。画面の結果を確認してください。');
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
    unawaited(asr.dispose());
    super.dispose();
  }

  String get engineLine {
    final s = support;
    if (s == null) return '';
    final where = s.onDevice ? '端末内で処理' : '音声はブラウザー／OS のサービスへ送信';
    return '${s.engine}　$where';
  }

  @override
  Widget build(BuildContext context) {
    final average = durations.isEmpty ? null : durations.reduce((a, b) => a + b) / durations.length;
    final narrow = MediaQuery.of(context).size.width < 600;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(narrow ? 14 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('pcm_asr demo', style: TextStyle(fontSize: narrow ? 24 : 30, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('record → VAD・SCD → pcm_asr　｜　$engineLine', style: const TextStyle(color: Colors.white70)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('話者変化で早期確定（逐次SCD）'),
                value: streaming,
                onChanged: running || busy || stopping ? null : (v) => setState(() => streaming = v),
              ),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: ready && !running && !busy && !stopping ? () => start(false) : null,
                    icon: const Icon(Icons.mic),
                    label: const Text('実マイクを開始'),
                  ),
                  OutlinedButton.icon(
                    onPressed: running ? stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止して確定'),
                  ),
                  OutlinedButton(
                    onPressed: ready && !running && !busy && !stopping ? () => start(true) : null,
                    child: const Text('共有音声で試す'),
                  ),
                  if (devices.isNotEmpty)
                    SizedBox(
                      width: narrow ? 260 : 300,
                      child: DropdownButtonFormField<String>(
                        initialValue: selected ?? '',
                        decoration: const InputDecoration(labelText: '入力マイク'),
                        items: [
                          const DropdownMenuItem(value: '', child: Text('OSの既定マイク')),
                          for (final d in devices) DropdownMenuItem(value: d.id, child: Text(d.label, overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: running ? null : (v) => setState(() => selected = v),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(status, style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: (level * 8).clamp(0, 1)),
              const SizedBox(height: 6),
              Text(
                '${(cursor / 16000).toStringAsFixed(1)}秒 / ${rows.length}区間 / ${tracker.speakers.length}話者候補　解析待ち $analysisQueue　ASR平均 ${average?.toStringAsFixed(0) ?? "—"}ms',
                style: const TextStyle(fontSize: 13),
              ),
              const Divider(height: 18),
              Expanded(
                child: rows.isEmpty
                    ? const Center(child: Text('開始して自然に話してください。2人なら交代時に少し間を入れてください。録音・会話文は保存しません。'))
                    : ListView.builder(
                        reverse: true,
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final r = rows[rows.length - 1 - index];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${speaker(r)}　${(r['start'] as double).toStringAsFixed(2)}–${(r['end'] as double).toStringAsFixed(2)}秒　${r['id']}',
                                    style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText(
                                    (r['text'] as String).isEmpty ? r['status'] as String : r['text'] as String,
                                    style: const TextStyle(fontSize: 20),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${r['status']}　ASR ${r['asr_ms']?.toStringAsFixed(0) ?? "—"}ms　音声区間末尾→表示 ${r['end_to_text_ms']?.toStringAsFixed(0) ?? "—"}ms',
                                    style: const TextStyle(color: Colors.white60, fontSize: 12),
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
