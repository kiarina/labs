import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_analysis/audio_analysis.dart';
import 'package:flutter/services.dart';

import 'engine.dart';
import 'wav.dart';

Future<Map<String, dynamic>> _fixture(String name) async =>
    jsonDecode(await rootBundle.loadString('assets/fixtures/$name.json')) as Map<String, dynamic>;

List<double> _nums(dynamic l) => (l as List).map((e) => (e as num).toDouble()).toList();

double _maxAbs(List<double> a, List<double> b) {
  var m = 0.0;
  for (var i = 0; i < math.min(a.length, b.length); i++) {
    m = math.max(m, (a[i] - b[i]).abs());
  }
  return m;
}

/// Runs each ONNX model on this platform on the fixture inputs and compares
/// with kiarina-python's outputs (onnxruntime on macOS arm64).
Future<Map<String, Object?>> runModelParity(ModelStore store, {int? threads}) async {
  final backend = defaultOnnxBackend(threads: threads);
  final pcm = Wav.parse((await rootBundle.load('assets/conversation_16k.wav')).buffer.asUint8List()).samples;
  final out = <String, Object?>{};

  Future<void> section(String name, Future<Map<String, Object?>> Function() f) async {
    final sw = Stopwatch()..start();
    try {
      out[name] = {...await f(), 'ms': sw.elapsedMilliseconds};
    } catch (e, st) {
      out[name] = {'error': '$e', 'stack': '$st'.split('\n').take(6).join('\n')};
    }
  }

  // The voice as kiarina builds it: VoiceDetector concatenates only the
  // chunks it keeps, so the voice is not a contiguous slice of the input.
  Float32List? voiceSamples;

  await section('silero_vad', () async {
    final want = _nums((await _fixture('vad'))['probabilities']);
    final vad = SileroVad(await backend.load(await store.ensure(ModelCatalog.sileroVad)));
    final got = <double>[];
    final times = <int>[];
    for (var i = 0; i < pcm.length; i += 512) {
      final sw = Stopwatch()..start();
      got.add(await vad.predict(Float32List.sublistView(pcm, i, math.min(i + 512, pcm.length)), 16000));
      times.add(sw.elapsedMicroseconds);
    }
    times.sort();
    final detector = VoiceDetector(SileroVad(await backend.load(await store.ensure(ModelCatalog.sileroVad))));
    for (var i = 0; i < pcm.length; i += 512) {
      final r = await detector.detect(Float32List.sublistView(pcm, i, math.min(i + 512, pcm.length)), 16000, i / 16000);
      voiceSamples ??= r.voice?.samples;
    }
    voiceSamples ??= detector.flush()?.samples;
    final above = [for (var i = 0; i < got.length; i++) (got[i] >= 0.5) == (want[i] >= 0.5)];
    return {
      'chunks': got.length,
      'max_abs_diff': _maxAbs(got, want),
      'threshold_agreement': above.where((x) => x).length / above.length,
      'call_us_p50': times[times.length ~/ 2],
      'call_us_p95': times[(times.length * 0.95).floor()],
    };
  });

  await section('pyannote', () async {
    final v = (await _fixture('scd'))['voices'][0] as Map<String, dynamic>;
    final scd = PyannoteScd(await backend.load(await store.ensure(ModelCatalog.pyannoteSegmentation)));
    final n = v['num_samples'] as int;
    if (voiceSamples!.length != n) throw StateError('voice length ${voiceSamples!.length} != $n');
    final r = await scd.predict(voiceSamples!, 16000);
    final want = [for (final row in v['speaker_probabilities'] as List) ..._nums(row)];
    return {
      'frames': r.frames,
      'frames_python': (v['speaker_probabilities'] as List).length,
      'frame_ms': r.frameMs,
      'max_abs_diff': _maxAbs(r.probabilities.toList(), want),
    };
  });

  await section('ecapa', () async {
    final e = await _fixture('ecapa');
    final scd = (await _fixture('scd'))['voices'][0] as Map<String, dynamic>;
    final speeches = scd['speeches'] as List;
    final embedder = EcapaSpeakerEmbedder(await backend.load(await store.ensure(ModelCatalog.ecapaTdnn)));
    final cos = <double>[];
    for (final s in e['speeches'] as List) {
      final sp = speeches[s['speech_index'] as int] as Map<String, dynamic>;
      final got = await embedder.embed(
          Float32List.sublistView(voiceSamples!, sp['start_sample'] as int, sp['end_sample'] as int), 16000);
      cos.add(cosineSimilarity(got, Float32List.fromList(_nums(s['embedding']))));
    }
    return {'speeches': cos.length, 'cosine_to_python_min': cos.reduce(math.min), 'cosine': cos};
  });

  await section('clap', () async {
    final c = await _fixture('clap');
    final embedder = ClapSoundEmbedder(await backend.load(await store.ensure(ModelCatalog.clapAudio)));
    final cos = <double>[];
    for (final w in c['windows'] as List) {
      final start = (w['window_index'] as int) * 160000;
      final got =
          await embedder.embed(Float32List.sublistView(pcm, start, start + (w['num_samples_16k'] as int)), 16000);
      cos.add(cosineSimilarity(got, Float32List.fromList(_nums(w['embedding']))));
    }
    return {'windows': cos.length, 'cosine': cos};
  });

  await section('yamnet', () async {
    final y = await _fixture('yamnet');
    final labels = YamnetTagger.parseClassMap(await store.readText(ModelCatalog.yamnetClassMap));
    final model = await backend.load(await store.ensure(yamnetOnnx));
    // kiarina-compatible (first 0.975 s) for parity, plus the full-window tagging this lab uses.
    final tagger = YamnetTagger(model, labels, firstCropOnly: true);
    final full = YamnetTagger(model, labels);
    final onnxRef = await _fixture('yamnet_onnx_parity');
    final results = <Object?>[];
    final refs = {for (final c in onnxRef['cases'] as List) c['case']: c['ort_default']};
    for (final w in y['windows'] as List) {
      final start = w['start_sample'] as int;
      final window = Float32List.sublistView(pcm, start, start + (w['num_samples'] as int));
      final got = await tagger.predict(window, 16000);
      final scores = [for (final p in got) p.score];
      final ref = refs.entries.firstWhere((e) => (e.key as String).startsWith('window${w['window_index']}')).value;
      final sw = Stopwatch()..start();
      final fullTags = await full.predict(window, 16000);
      results.add({
        'window': w['window_index'],
        'max_abs_diff_vs_python_onnx': _maxAbs(scores, _nums(ref['scores'])),
        'max_abs_diff_vs_tflite': _maxAbs(scores, _nums(w['clip_scores'])),
        'top3_first_crop': [for (final t in YamnetTagger.topK(got, 3)) t.toJson()],
        'top3_python': w['top3'],
        'top3_full_window': [for (final t in YamnetTagger.topK(fullTags, 3)) t.toJson()],
        'full_window_ms': sw.elapsedMilliseconds,
      });
    }
    return {'windows': results};
  });

  return out;
}
