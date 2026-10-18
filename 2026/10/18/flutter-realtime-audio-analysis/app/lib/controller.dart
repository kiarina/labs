import 'dart:async';
import 'dart:convert';

import 'package:audio_analysis/audio_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'engine.dart';
import 'parity.dart';
import 'report_io.dart' if (dart.library.js_interop) 'report_web.dart';
import 'wav.dart';

String get platformName => kIsWeb ? 'web' : defaultTargetPlatform.name;

double nowSeconds() => DateTime.now().microsecondsSinceEpoch / 1e6;

/// The lab's stand-in for the body: permission → model download → the
/// brain turns the mic on → analysis runs → results accumulate → the brain
/// reads them back with a tool ([recall]).
class HearingController extends ChangeNotifier {
  HearingController({this.config = const EngineConfig()});

  EngineConfig config;
  final store = ModelStore();
  final hearing = HearingStore();
  final _recorder = AudioRecorder();

  String permission = 'unknown';
  final downloads = <String, ModelProgress>{};
  bool downloading = false;
  bool downloaded = false;
  String? error;
  Engine? engine;
  bool loading = false;
  bool micOn = false;
  bool replaying = false;
  final recent = <HearingEvent>[];
  final log = <String>[];
  StreamSubscription<Uint8List>? _mic;
  StreamSubscription<HearingEvent>? _eventsSub;
  double? _micStart;
  final _micRms = <double>[];
  int _micSamples = 0;

  void _log(String s) {
    final line = '${DateTime.now().toIso8601String().substring(11, 23)} $s';
    log.add(line);
    if (log.length > 200) log.removeAt(0);
    debugPrint('[hearing] $s');
    notifyListeners();
  }

  /// Step 1: ask for the mic. Granting starts the model download.
  Future<void> requestPermission() async {
    final ok = await _recorder.hasPermission();
    permission = ok ? 'granted' : 'denied';
    _log('microphone permission: $permission');
    if (ok) unawaited(downloadModels());
  }

  Future<void> downloadModels() async {
    if (downloading || downloaded) return;
    downloading = true;
    error = null;
    notifyListeners();
    final sw = Stopwatch()..start();
    try {
      await Engine.download(store, config, (p) {
        downloads[p.file.filename] = p;
        notifyListeners();
      });
      downloaded = true;
      _log('models ready in ${sw.elapsedMilliseconds} ms');
    } catch (e) {
      error = '$e';
      _log('download failed: $e');
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  Future<Engine> ensureEngine() async {
    if (engine != null) return engine!;
    if (!downloaded) await downloadModels();
    if (!downloaded) throw StateError('models are not ready: $error');
    loading = true;
    notifyListeners();
    try {
      final e = await Engine.load(store, config, hearing: hearing);
      _eventsSub = e.analyzer.events.listen((ev) {
        recent.add(ev);
        if (recent.length > 200) recent.removeAt(0);
        _log('${ev.kind}: ${_summary(ev)}');
      });
      e.analyzer.errors.listen((err) => _log('analysis error: $err'));
      engine = e;
      _log('engine loaded ${jsonEncode(e.loadTimes.toJson())} asr=${e.asr.name}');
      return e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Step 2 (the brain's set_senses): turning the mic on starts the analysis.
  Future<void> setMic(bool on) async {
    if (on == micOn) return;
    if (on) {
      if (permission != 'granted') await requestPermission();
      if (permission != 'granted') return;
      final e = await ensureEngine();
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _micStart = null;
      _micSamples = 0;
      _mic = stream.listen((bytes) {
        final samples = pcm16ToFloat32(bytes);
        _micRms.add(rms(samples));
        // Time of the first sample: approximated at the first callback, then
        // advanced by the sample count so chunk times don't jitter.
        _micStart ??= nowSeconds() - samples.length / 16000;
        e.analyzer.feed(samples, _micStart! + _micSamples / 16000);
        _micSamples += samples.length;
      });
      micOn = true;
      _log('mic on');
    } else {
      await _mic?.cancel();
      _mic = null;
      await _recorder.stop();
      micOn = false;
      _log('mic off');
      await engine?.analyzer.flush();
    }
    notifyListeners();
  }

  /// Feeds the bundled 14 s two-speaker WAV as if it were the mic.
  Future<Map<String, Object?>> replayWav({bool realtime = true}) async {
    final e = await ensureEngine();
    replaying = true;
    notifyListeners();
    final wav = Wav.parse((await rootBundle.load('assets/conversation_16k.wav')).buffer.asUint8List());
    final block = wav.sampleRate ~/ 10; // 100 ms, like a mic callback
    final start = nowSeconds();
    final sw = Stopwatch()..start();
    for (var i = 0; i < wav.samples.length; i += block) {
      final end = (i + block).clamp(0, wav.samples.length);
      e.analyzer.feed(Float32List.sublistView(wav.samples, i, end), start + i / wav.sampleRate);
      if (realtime) {
        final due = (end / wav.sampleRate * 1000).round();
        final wait = due - sw.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      } else {
        await Future<void>.delayed(Duration.zero);
      }
    }
    final fedMs = sw.elapsedMilliseconds;
    await e.analyzer.flush();
    final doneMs = sw.elapsedMilliseconds;
    replaying = false;
    notifyListeners();
    final events = hearing.query(since: start - 1);
    return {
      'audio_s': wav.samples.length / wav.sampleRate,
      'fed_ms': fedMs,
      'done_ms': doneMs,
      'latency_after_end_ms': doneMs - (wav.samples.length / wav.sampleRate * 1000).round(),
      'events': [
        for (final ev in events)
          {
            ..._relative(ev.toJson(), start),
            // how long after the end of the sound the result was ready
            'lag_s': double.parse((ev.createdAt.microsecondsSinceEpoch / 1e6 - ev.end).toStringAsFixed(2)),
          },
      ],
    };
  }

  /// The brain-only tool: what was heard in the last [minutes].
  Map<String, Object?> recall({double minutes = 5, Set<String>? kinds, int limit = 50}) {
    final now = nowSeconds();
    final events = hearing.query(since: now - minutes * 60, kinds: kinds, limit: limit);
    return {
      'now': now,
      'mic': micOn,
      'events': [
        for (final e in events) {...e.toJson(), 'seconds_ago': double.parse((now - e.end).toStringAsFixed(1))},
      ],
    };
  }

  Map<String, Object?> _relative(Map<String, Object?> j, double origin) => {
        ...j,
        'start': double.parse(((j['start'] as double) - origin).toStringAsFixed(3)),
        'end': double.parse(((j['end'] as double) - origin).toStringAsFixed(3)),
      };

  String _summary(HearingEvent e) => switch (e) {
        SpeechEvent s => '[${s.speakerKind == 'speaker' ? 'S${s.speaker}' : s.speakerKind}] ${s.text} (${s.asrMs} ms)',
        AmbientEvent a => a.tags.map((t) => '${t.label} ${t.score.toStringAsFixed(2)}').join(', '),
      };

  /// `--dart-define=AUTO=replay|replay-fast`: download, load, replay the WAV,
  /// write a report and (native) exit.
  Future<void> runAuto(String mode) async {
    final report = <String, Object?>{'platform': platformName, 'mode': mode, 'config': {
      'whisper': config.whisperModel,
      'language': config.language,
      'ort_threads': config.threads,
      'whisper_threads': config.whisperThreads,
      'fit_audio_ctx': config.fitAudioCtx,
      'min_silence_ms': config.minSilenceMs,
      'max_voice_ms': config.maxVoiceMs,
      'speaker_threshold': config.speakerThreshold,
      'asr_speakers_only': config.asrSpeakersOnly,
      'asr_min_seconds': config.asrMinSeconds,
      'new_speaker_min_seconds': config.newSpeakerMinSeconds,
    }};
    try {
      final dl = Stopwatch()..start();
      await downloadModels();
      report['download_ms'] = dl.elapsedMilliseconds;
      if (mode == 'mic') {
        // The real capture path: permission → models → the brain turns the
        // mic on for MIC_SECONDS → off → the brain reads back what was heard.
        await requestPermission();
        report['permission'] = permission;
        while (downloading || (!downloaded && permission == 'granted' && error == null)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        final e = await ensureEngine();
        report['load_ms'] = e.loadTimes.toJson();
        report['asr'] = e.asr.name;
        final on = nowSeconds();
        await setMic(true);
        await Future<void>.delayed(const Duration(seconds: int.fromEnvironment('MIC_SECONDS', defaultValue: 16)));
        await setMic(false);
        report['mic_samples'] = _micSamples;
        report['mic_rms_avg'] = _micRms.isEmpty ? 0 : _micRms.reduce((a, b) => a + b) / _micRms.length;
        report['mic_rms_max'] = _micRms.isEmpty ? 0 : _micRms.reduce((a, b) => a > b ? a : b);
        report['mic_callbacks'] = _micRms.length;
        report['mic_s'] = nowSeconds() - on;
        report['stats'] = e.analyzer.statsJson();
        report['recall'] = recall(minutes: 3);
        // embeddings stay on the device side for offline tuning; not part of the report
        await saveReport('mic-embeddings.json', jsonEncode([
          for (final ev in hearing.query(since: on - 1, kinds: {'speech'}, limit: 1000)) ev.toJson(embeddings: true),
        ]));
        throw const _Done();
      }
      if (mode == 'parity') {
        report['parity'] = await runModelParity(store, threads: config.threads);
        throw const _Done();
      }
      final e = await ensureEngine();
      report['load_ms'] = e.loadTimes.toJson();
      report['asr'] = e.asr.name;
      report['replay'] = await replayWav(realtime: mode == 'replay');
      // A second pass shows warm numbers (first ASR/ONNX calls include setup).
      hearing.clear();
      report['replay_warm'] = await replayWav(realtime: mode == 'replay');
      report['stats'] = e.analyzer.statsJson();
      report['recall_example'] = recall(minutes: 1, kinds: {'speech'}, limit: 3);
    } on _Done {
      // parity only
    } catch (err, st) {
      report['error'] = '$err';
      report['stack'] = '$st';
    }
    final json = const JsonEncoder.withIndent(' ').convert(report);
    // logcat cuts a line at ~1 KB, so the report goes out in numbered parts.
    final line = jsonEncode(report);
    const size = 700;
    final parts = (line.length / size).ceil();
    for (var i = 0; i < parts; i++) {
      final end = (i + 1) * size < line.length ? (i + 1) * size : line.length;
      // ignore: avoid_print
      print('HEARING_LAB_REPORT ${i + 1}/$parts ${line.substring(i * size, end)}');
    }
    final path = await saveReport('report-$platformName.json', json);
    _log('report saved: ${path ?? 'page'}');
    if (const bool.fromEnvironment('AUTO_EXIT')) exitApp();
  }

  Future<Map<String, Object?>> modelParity() async {
    await downloadModels();
    final r = await runModelParity(store, threads: config.threads);
    _log('parity ${jsonEncode(r)}');
    return r;
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _mic?.cancel();
    _recorder.dispose();
    engine?.close();
    super.dispose();
  }
}

class _Done {
  const _Done();
}
