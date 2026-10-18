// Logic parity with kiarina-python using the fixtures in ../../fixtures.
// Model outputs are replayed from the fixtures, so these run without ONNX
// Runtime; the in-app parity run checks the models themselves.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_analysis/audio_analysis.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

final _lab = Directory.current.parent.parent.path;

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('$_lab/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

Float32List _wav() {
  final bytes = File('$_lab/work/conversation_16k.wav').readAsBytesSync();
  final d = ByteData.sublistView(bytes);
  // the lab's WAV is written by ffmpeg with a 44-byte header (checked by sha)
  var offset = 12;
  while (String.fromCharCodes(bytes.sublist(offset, offset + 4)) != 'data') {
    offset += 8 + d.getUint32(offset + 4, Endian.little);
  }
  final n = d.getUint32(offset + 4, Endian.little) ~/ 2;
  return Float32List.fromList([for (var i = 0; i < n; i++) d.getInt16(offset + 8 + i * 2, Endian.little) / 32768.0]);
}

/// Replays recorded VAD probabilities.
class _ReplayVadModel implements OnnxModel {
  _ReplayVadModel(this.probs);

  final List<double> probs;
  var _i = 0;

  @override
  List<String> get inputNames => ['input', 'state', 'sr'];

  @override
  List<String> get outputNames => ['output', 'stateN'];

  @override
  Future<Map<String, Tensor>> run(Map<String, Tensor> inputs) async => {
        'output': Tensor.float32(Float32List.fromList([probs[_i++]]), [1, 1]),
        'stateN': Tensor.float32(Float32List(256), [2, 1, 128]),
      };

  @override
  Future<void> close() async {}
}

class _ReplayScd implements ScdPredictor {
  _ReplayScd(this.result);

  final ScdResult result;

  @override
  Future<ScdResult> predict(Float32List samples, int sourceRate) async => result;
}

String _sha(Float32List f) => sha256.convert(f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes)).toString();

void main() {
  final pcm = _wav();
  final input = _fixture('input');

  test('PCM16 → float32 matches Python', () {
    expect(pcm.length, input['num_samples']);
    expect(_sha(pcm), input['float32_sha256']);
  });

  group('VoiceDetector', () {
    final vad = _fixture('vad');
    final probs = (vad['probabilities'] as List).cast<num>().map((e) => e.toDouble()).toList();

    Future<List<Voice>> run(VoiceDetectorSettings s) async {
      final detector = VoiceDetector(SileroVad(_ReplayVadModel(probs)), settings: s);
      final voices = <Voice>[];
      for (var i = 0; i < pcm.length; i += 512) {
        final chunk = Float32List.sublistView(pcm, i, math.min(i + 512, pcm.length));
        final r = await detector.detect(chunk, 16000, i / 16000);
        if (r.voice != null) voices.add(r.voice!);
      }
      final last = detector.flush();
      if (last != null) voices.add(last);
      return voices;
    }

    void expectVoices(List<Voice> got, List<dynamic> want) {
      expect(got.length, want.length);
      for (var i = 0; i < got.length; i++) {
        final w = want[i] as Map<String, dynamic>;
        expect(got[i].samples.length, w['num_samples'], reason: 'voice $i length');
        expect(got[i].startTimestamp, closeTo((w['start_timestamp'] as num).toDouble(), 1e-6));
        expect(got[i].endTimestamp, closeTo((w['end_timestamp'] as num).toDouble(), 1e-6));
        if (w['samples_sha256'] != null) expect(_sha(got[i].samples), w['samples_sha256']);
      }
    }

    test('defaults', () async => expectVoices(await run(const VoiceDetectorSettings()), vad['voices'] as List));

    test('variants', () async {
      for (final v in vad['voice_detector_variants'] as List) {
        final s = v['settings'] as Map<String, dynamic>;
        expectVoices(
          await run(VoiceDetectorSettings(
            threshold: (s['threshold'] as num).toDouble(),
            minSilenceMs: s['min_silence_ms'] as int,
            voicePadMs: s['voice_pad_ms'] as int,
          )),
          v['voices'] as List,
        );
      }
    });
  });

  test('SpeakerChangeDetector splits like Python', () async {
    final scd = _fixture('scd');
    final vad = _fixture('vad');
    final voiceStart = (vad['voices'][0]['start_sample'] as int);
    for (final v in scd['voices'] as List) {
      final rows = (v['speaker_probabilities'] as List).cast<List>();
      final flat = Float32List.fromList([for (final r in rows) for (final x in r) (x as num).toDouble()]);
      final detector = SpeakerChangeDetector(_ReplayScd(ScdResult(flat, 3, (v['frame_ms_exact'] as num).toDouble())));
      final n = v['num_samples'] as int;
      final speeches = await detector.detect(Float32List(n), 16000, 0);
      final want = v['speeches'] as List;
      expect(speeches.length, want.length);
      for (var i = 0; i < speeches.length; i++) {
        expect(speeches[i].samples.length, want[i]['num_samples']);
        expect(speeches[i].speakerIndex, want[i]['speaker_index']);
        expect(speeches[i].kind, want[i]['kind']);
      }
      expect(voiceStart, 0);
    }
  });

  test('CLAP log-mel front end matches Python', () {
    final clap = _fixture('clap');
    final embedder = ClapSoundEmbedder(_ReplayVadModel(const []));
    for (final w in clap['windows'] as List) {
      final start = (w['window_index'] as int) * 160000;
      final n = w['num_samples_16k'] as int;
      final f = embedder.extractFeatures(Float32List.sublistView(pcm, start, start + n), 16000);
      expect(f.resampledLength, w['num_samples_48k']);
      final resampled = resampleLinear(Float32List.fromList(pcm.sublist(start, start + n)), 16000, 48000);
      // ignore: avoid_print
      print('48 kHz resample sha equal: ${_sha(resampled) == w['resampled_48k_sha256']}');
      expect(f.isLonger, w['is_longer']);
      final want = w['input_features'] as Map<String, dynamic>;
      expect([1, 1, f.frames, f.bins], want['shape']);
      final mean = f.features.reduce((a, b) => a + b) / f.features.length;
      expect(mean, closeTo((want['mean'] as num).toDouble(), 1e-3));
      var maxDiff = 0.0;
      final first = (want['first3_frames'] as List).cast<List>();
      for (var t = 0; t < 3; t++) {
        for (var m = 0; m < 64; m++) {
          maxDiff = math.max(maxDiff, (f.features[t * 64 + m] - (first[t][m] as num)).abs());
        }
      }
      // fixtures are rounded to 6 significant digits
      expect(maxDiff, lessThan(1e-3), reason: 'window ${w['window_index']}');
      final bin = File('$_lab/work/fixtures-bin/clap_window${w['window_index']}_input_features.f32');
      if (bin.existsSync()) {
        final ref = bin.readAsBytesSync().buffer.asFloat32List();
        var d = 0.0;
        for (var i = 0; i < ref.length; i++) {
          d = math.max(d, (ref[i] - f.features[i]).abs());
        }
        // ignore: avoid_print
        print('CLAP window ${w['window_index']} full max |Δ| = $d dB (sha equal: ${_sha(f.features) == want['sha256']})');
        expect(d, lessThan(1e-3));
      }
    }
  });
}
