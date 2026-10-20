import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pcm_asr/pcm_asr.dart';
import 'package:tts_pcm/tts_pcm.dart';

import 'platform.dart';

/// Sentences synthesized on every platform. The ASR round trip compares the
/// recognized text with these (punctuation and spaces ignored).
const texts = {
  'ja-short': ('ja-JP', 'こんにちは。今日はいい天気ですね。'),
  'ja-long': (
    'ja-JP',
    '岐阜県の白川郷は、合掌造りの集落として知られています。冬になると雪に覆われ、夜にはライトアップが行われることもあります。',
  ),
  'en-short': ('en-US', 'Hello. The weather is nice today, isn\'t it?'),
};

void main() {
  configurePlatform();
  runApp(const MaterialApp(home: ProbePage()));
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  final _tts = TtsPcm.instance;
  String _status = 'idle';

  @override
  void initState() {
    super.initState();
    final raw = configJson();
    final config = raw == null
        ? <String, Object?>{}
        : jsonDecode(raw) as Map<String, Object?>;
    if (config['run'] != false && raw != null) unawaited(_run(config));
  }

  void _set(String s) {
    if (mounted) setState(() => _status = s);
  }

  /// Synthesizes once and measures timing and the audio.
  Future<(Map<String, Object?>, Int16List?, int)> _synth(
    String text, {
    String? language,
    String? voice,
  }) async {
    final sw = Stopwatch()..start();
    final r = <String, Object?>{};
    final parts = <Int16List>[];
    int? firstMs;
    var rate = 0;
    String? format;
    final sizes = <int>[];
    try {
      await for (final c in _tts
          .synthesize(text, language: language, voice: voice)
          .timeout(const Duration(seconds: 60))) {
        firstMs ??= sw.elapsedMilliseconds;
        rate = c.sampleRate;
        format ??= c.nativeFormat;
        parts.add(c.samples);
        sizes.add(c.samples.length);
      }
    } catch (e) {
      r['error'] = '$e';
    }
    final totalMs = sw.elapsedMilliseconds;
    final n = parts.fold<int>(0, (a, b) => a + b.length);
    final pcm = Int16List(n);
    var o = 0;
    for (final p in parts) {
      pcm.setAll(o, p);
      o += p.length;
    }
    final audioMs = rate == 0 ? 0 : n * 1000 ~/ rate;
    r.addAll({
      'firstChunkMs': firstMs,
      'totalMs': totalMs,
      'audioMs': audioMs,
      'realTimeFactor': audioMs == 0 ? null : totalMs / audioMs,
      'chunks': parts.length,
      'chunkSamples': {
        if (sizes.isNotEmpty) 'min': sizes.reduce(math.min),
        if (sizes.isNotEmpty) 'max': sizes.reduce(math.max),
      },
      'sampleRate': rate,
      'nativeFormat': format,
      ..._level(pcm, rate),
    });
    return (r, n == 0 ? null : pcm, rate);
  }

  static Map<String, Object?> _level(Int16List pcm, int rate) {
    if (pcm.isEmpty || rate == 0) return {};
    var peak = 0;
    var sum = 0.0;
    var lead = -1;
    for (var i = 0; i < pcm.length; i++) {
      final a = pcm[i].abs();
      if (a > peak) peak = a;
      sum += a * a.toDouble();
      if (lead < 0 && a > 328) lead = i; // -40 dBFS
    }
    final rms = math.sqrt(sum / pcm.length) / 32768;
    return {
      'peakDbfs': 20 * math.log(peak / 32768) / math.ln10,
      'rmsDbfs': rms == 0 ? null : 20 * math.log(rms) / math.ln10,
      'leadingSilenceMs': lead < 0 ? null : lead * 1000 ~/ rate,
    };
  }

  /// Linear resampling to 16 kHz for the recognizer.
  static Int16List _to16k(Int16List pcm, int rate) {
    if (rate == 16000) return pcm;
    final n = pcm.length * 16000 ~/ rate;
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      final x = i * rate / 16000;
      final j = x.floor();
      final f = x - j;
      final a = pcm[math.min(j, pcm.length - 1)];
      final b = pcm[math.min(j + 1, pcm.length - 1)];
      out[i] = (a + (b - a) * f).round();
    }
    return out;
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[\s、。，．,.!?！？'’\-]"), '');

  /// Character error rate (Levenshtein distance / reference length).
  static double _cer(String ref, String hyp) {
    final a = _norm(ref).runes.toList();
    final b = _norm(hyp).runes.toList();
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        cur[j] = [
          prev[j] + 1,
          cur[j - 1] + 1,
          prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
        ].reduce(math.min);
      }
      prev = cur;
    }
    return a.isEmpty ? 0 : prev[b.length] / a.length;
  }

  Future<Map<String, Object?>> _asr(
    String key,
    String text,
    String locale,
    Int16List pcm,
    int rate,
  ) async {
    final pcm16 = _to16k(pcm, rate);
    final bytes = Uint8List.view(pcm16.buffer, 0, pcm16.length * 2);
    try {
      final res = await const PcmAsr().transcribe(
        TranscribeRequest(
          id: 'asr-$key',
          audio: PcmSegment(pcm16le: bytes, sampleRate: 16000),
          locale: locale,
        ),
      );
      return {
        'engine': res.engine,
        'text': res.text,
        'cer': _cer(text, res.text),
        'elapsedMs': res.elapsed.inMilliseconds,
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }

  Future<void> _run(Map<String, Object?> config) async {
    final report = <String, Object?>{'platform': platformName()};
    final asr = config['asr'] != false;

    _set('voices');
    final sw = Stopwatch()..start();
    try {
      final all = await _tts.voices();
      report['voicesMs'] = sw.elapsedMilliseconds;
      report['voiceCount'] = all.length;
      report['jaVoices'] = [
        for (final v in all)
          if (v.language.toLowerCase().startsWith('ja')) v.toJson(),
      ];
      report['enVoiceCount'] = all
          .where((v) => v.language.toLowerCase().startsWith('en'))
          .length;
    } catch (e) {
      report['voicesError'] = '$e';
    }

    if (asr) {
      for (final locale in ['ja-JP', 'en-US']) {
        _set('asr prepare $locale');
        try {
          await const PcmAsr().prepare(locale: locale);
        } catch (e) {
          report['asrPrepareError-$locale'] = '$e';
        }
      }
    }

    // Each sentence twice with the language's default voice: the first call
    // includes engine start-up.
    final runs = <Map<String, Object?>>[];
    for (final e in texts.entries) {
      for (var i = 0; i < 2; i++) {
        _set('synth ${e.key} #$i');
        final (r, pcm, rate) = await _synth(e.value.$2, language: e.value.$1);
        r['text'] = e.key;
        r['attempt'] = i;
        if (pcm != null) {
          await saveWav('${e.key}-$i.wav', pcm, rate);
          if (asr && i == 1) {
            _set('asr ${e.key}');
            r['asr'] = await _asr(e.key, e.value.$2, e.value.$1, pcm, rate);
          }
        }
        runs.add(r);
      }
    }
    report['runs'] = runs;

    // Every Japanese voice on the short sentence.
    final perVoice = <Map<String, Object?>>[];
    for (final v in (report['jaVoices'] as List? ?? const []).cast<Map>()) {
      _set('voice ${v['name']}');
      final (r, pcm, rate) = await _synth(
        texts['ja-short']!.$2,
        voice: v['id'] as String,
      );
      r['voice'] = v['name'];
      r['quality'] = v['quality'];
      if (pcm != null && asr) {
        r['asr'] = await _asr(
          'voice',
          texts['ja-short']!.$2,
          'ja-JP',
          pcm,
          rate,
        );
      }
      perVoice.add(r);
    }
    report['jaPerVoice'] = perVoice;

    // Cancel after the first chunk: no more chunks may arrive, and the next
    // request must still work.
    _set('cancel');
    final cancel = <String, Object?>{};
    final lateBefore = _tts.lateChunks;
    var cancelled = false;
    final c0 = Completer<void>();
    late StreamSubscription<TtsChunk> sub;
    sub = _tts.synthesize(texts['ja-long']!.$2, language: 'ja-JP').listen(
      (c) {
        if (cancelled) return;
        cancelled = true;
        unawaited(sub.cancel());
        if (!c0.isCompleted) c0.complete();
      },
      onError: (Object e) {
        cancel['error'] = '$e';
        if (!c0.isCompleted) c0.complete();
      },
      onDone: () {
        if (!c0.isCompleted) c0.complete();
      },
    );
    await c0.future.timeout(const Duration(seconds: 30), onTimeout: () {});
    await Future<void>.delayed(const Duration(seconds: 2));
    cancel['chunksAfterCancel'] = _tts.lateChunks - lateBefore;
    final (next, _, _) = await _synth(texts['ja-short']!.$2, language: 'ja-JP');
    cancel['nextRequest'] = next;
    report['cancel'] = cancel;

    // Two requests at once.
    _set('concurrent');
    final both = await Future.wait([
      _synth(texts['ja-short']!.$2, language: 'ja-JP'),
      _synth(texts['en-short']!.$2, language: 'en-US'),
    ]);
    report['concurrent'] = [for (final b in both) b.$1];

    final json = jsonEncode(report);
    writeResult(json);
    _set('done');
    if (config['exit'] == true) exitApp();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('tts_pcm — $_status')),
    body: Center(
      child: FilledButton(
        onPressed: () => unawaited(_run(const {})),
        child: const Text('Run'),
      ),
    ),
  );
}
