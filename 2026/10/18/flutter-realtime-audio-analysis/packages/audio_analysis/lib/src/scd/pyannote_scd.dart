import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pcm.dart';
import '../onnx.dart';

class ScdResult {
  ScdResult(this.probabilities, this.numSpeakers, this.frameMs);

  /// Row-major [frames, numSpeakers].
  final Float32List probabilities;
  final int numSpeakers;
  final double frameMs;

  int get frames => numSpeakers == 0 ? 0 : probabilities.length ~/ numSpeakers;

  List<double> frame(int i) => probabilities.sublist(i * numSpeakers, (i + 1) * numSpeakers);
}

abstract class ScdPredictor {
  Future<ScdResult> predict(Float32List samples, int sourceRate);
}

/// Port of kiarina's `PyannoteSCDProvider` (pyannote-segmentation-3.0 ONNX,
/// powerset output converted to per-speaker probabilities).
class PyannoteScd implements ScdPredictor {
  PyannoteScd(
    this.model, {
    this.sampleRate = 16000,
    this.windowDuration = 10.0,
    this.numSpeakers = 3,
    this.maxSpeakersPerFrame = 2,
  }) : _mapping = _powersetMapping(numSpeakers, maxSpeakersPerFrame);

  final OnnxModel model;
  final int sampleRate;
  final double windowDuration;
  final int numSpeakers;
  final int maxSpeakersPerFrame;
  final List<List<double>> _mapping;

  @override
  Future<ScdResult> predict(Float32List samples, int sourceRate) async {
    samples = resampleLinear(samples, sourceRate, sampleRate);
    if (samples.isEmpty) return ScdResult(Float32List(0), numSpeakers, windowDuration * 1000);

    final window = pyRound(windowDuration * sampleRate);
    final chunks = <Float32List>[];
    var framesPerChunk = 0;
    for (var start = 0; start < samples.length; start += window) {
      final chunk = Float32List(window);
      final end = math.min(start + window, samples.length);
      chunk.setRange(0, end - start, samples, start);
      final probs = await _predictChunk(chunk);
      framesPerChunk = probs.length ~/ numSpeakers;
      chunks.add(probs);
    }
    final all = concatFloat32(chunks);
    final frameMs = windowDuration * 1000 / framesPerChunk;
    final expected = math.max(1, pyRound(samples.length * 1000 / sampleRate / frameMs));
    final frames = math.min(expected, all.length ~/ numSpeakers);
    return ScdResult(Float32List.fromList(all.sublist(0, frames * numSpeakers)), numSpeakers, frameMs);
  }

  Future<Float32List> _predictChunk(Float32List chunk) async {
    final names = model.inputNames.toSet();
    final inputName = ['waveform', 'waveforms', 'input', 'audio', 'x', 'input_values']
        .firstWhere(names.contains, orElse: () => model.inputNames.first);
    final outputs = await model.run({inputName: Tensor.float32(chunk, [1, 1, chunk.length])});
    final out = outputs[model.outputNames.first]!;
    // Squeeze to [frames, classes].
    final dims = out.shape.where((d) => d != 1).toList();
    var data = out.float32;
    var frames = dims[0];
    var classes = dims[1];
    final candidates = {numSpeakers, _mapping.length};
    if (candidates.contains(frames) && !candidates.contains(classes)) {
      data = _transpose(data, frames, classes);
      final t = frames;
      frames = classes;
      classes = t;
    }
    if (classes == numSpeakers) return data; // multilabel
    if (classes != _mapping.length) {
      throw StateError('Unexpected pyannote output shape ${out.shape}');
    }
    // powerset log probs -> exp -> @ mapping
    final result = Float32List(frames * numSpeakers);
    for (var f = 0; f < frames; f++) {
      for (var c = 0; c < classes; c++) {
        final p = math.exp(data[f * classes + c]);
        final row = _mapping[c];
        for (var s = 0; s < numSpeakers; s++) {
          if (row[s] != 0) result[f * numSpeakers + s] += p * row[s];
        }
      }
    }
    return result;
  }

  static Float32List _transpose(Float32List d, int rows, int cols) {
    final out = Float32List(d.length);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        out[c * rows + r] = d[r * cols + c];
      }
    }
    return out;
  }

  static List<List<double>> _powersetMapping(int numSpeakers, int maxPerFrame) {
    final rows = <List<double>>[];
    void combos(int size, int start, List<int> current) {
      if (current.length == size) {
        final row = List<double>.filled(numSpeakers, 0);
        for (final s in current) {
          row[s] = 1;
        }
        rows.add(row);
        return;
      }
      for (var i = start; i < numSpeakers; i++) {
        combos(size, i + 1, [...current, i]);
      }
    }

    for (var size = 0; size <= maxPerFrame; size++) {
      combos(size, 0, []);
    }
    return rows;
  }
}
