import 'dart:convert';
import 'dart:typed_data';

import '../dsp/pcm.dart';
import '../onnx.dart';

class TagPrediction {
  const TagPrediction(this.label, this.score);

  final String label;
  final double score;

  Map<String, Object?> toJson() => {'label': label, 'score': score};
}

/// Port of kiarina's `YamnetAudioTaggingProvider` on the same TFLite
/// converted to ONNX.
///
/// The pinned TFLite (`lite-model/yamnet/classification/tflite/1`) is a
/// single-patch classifier: it reads only waveform[0:15600] (0.975 s) and
/// returns one frame, and it fails on shorter input. kiarina therefore tags a
/// 10 s window by its first second. Here the window is cut into 0.975 s
/// crops with YAMNet's own 0.48 s hop and the crop scores are aggregated
/// (short input is zero-padded). [firstCropOnly] reproduces kiarina.
class YamnetTagger {
  YamnetTagger(
    this.model,
    this.labels, {
    this.sampleRate = 16000,
    this.aggregation = 'mean',
    this.cropSamples = 15600,
    this.hopSamples = 7680,
    this.firstCropOnly = false,
  });

  final OnnxModel model;
  final List<String> labels;
  final int sampleRate;
  final String aggregation;
  final int cropSamples;
  final int hopSamples;
  final bool firstCropOnly;

  /// Parses yamnet_class_map.csv (index,mid,display_name).
  static List<String> parseClassMap(String csv) {
    final lines = const LineSplitter().convert(csv);
    final header = _splitCsv(lines.first);
    final col = header.indexOf('display_name');
    return [
      for (final line in lines.skip(1))
        if (line.trim().isNotEmpty) _splitCsv(line)[col],
    ];
  }

  static List<String> _splitCsv(String line) {
    final out = <String>[];
    final buf = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (c == ',' && !quoted) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    out.add(buf.toString());
    return out;
  }

  Future<List<TagPrediction>> predict(Float32List samples, int sourceRate) async {
    samples = resampleLinear(samples, sourceRate, sampleRate);
    final classes = labels.length;
    final crops = <Float32List>[];
    if (firstCropOnly || samples.length <= cropSamples) {
      crops.add(_crop(samples, 0));
    } else {
      for (var start = 0; start + cropSamples <= samples.length; start += hopSamples) {
        crops.add(_crop(samples, start));
      }
    }
    final clip = List<double>.filled(classes, aggregation == 'max' ? double.negativeInfinity : 0);
    for (final crop in crops) {
      final outputs = await model.run({model.inputNames.first: Tensor.float32(crop, [crop.length])});
      final scores = outputs.values.firstWhere((t) => t.shape.isNotEmpty && t.shape.last == classes).float32;
      final frames = scores.length ~/ classes;
      for (var f = 0; f < frames; f++) {
        for (var c = 0; c < classes; c++) {
          final v = scores[f * classes + c];
          if (aggregation == 'max') {
            if (v > clip[c]) clip[c] = v;
          } else {
            clip[c] += v / (frames * crops.length);
          }
        }
      }
    }
    return [for (var c = 0; c < classes; c++) TagPrediction(labels[c], clip[c])];
  }

  Float32List _crop(Float32List samples, int start) {
    final out = Float32List(cropSamples);
    final end = (start + cropSamples).clamp(0, samples.length);
    out.setRange(0, end - start, samples, start);
    return out;
  }

  static List<TagPrediction> topK(List<TagPrediction> predictions, int k, {double? threshold}) {
    final sorted = [...predictions]..sort((a, b) => b.score.compareTo(a.score));
    return sorted.where((p) => threshold == null || p.score >= threshold).take(k).toList();
  }
}
