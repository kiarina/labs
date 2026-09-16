import 'dart:math' as math;
import 'dart:typed_data';

const int inputSize = 640;
const double scoreThreshold = 0.5;

class Detection {
  const Detection(this.label, this.score, this.bbox);

  final String label;
  final double score;

  /// x1, y1, x2, y2 in original image pixels.
  final List<int> bbox;

  Map<String, Object> toJson() => {'label': label, 'score': score, 'bbox': bbox};
}

/// Fixed-point (Q11) bilinear resize table with OpenCV's half-pixel source mapping.
class _LinearTable {
  _LinearTable(int srcSize, int dstSize)
      : offsets = Int32List(dstSize),
        alpha0 = Int32List(dstSize),
        alpha1 = Int32List(dstSize),
        interpolate = List<bool>.filled(dstSize, true) {
    final scale = srcSize / dstSize;
    final f = Float32List(1);
    for (var d = 0; d < dstSize; d++) {
      f[0] = (d + 0.5) * scale - 0.5;
      var s = f[0].floor();
      f[0] = f[0] - s;
      if (s < 0) {
        f[0] = 0;
        s = 0;
      }
      if (s + 1 >= srcSize) {
        interpolate[d] = false;
        if (s >= srcSize - 1) {
          f[0] = 0;
          s = srcSize - 1;
        }
      }
      offsets[d] = s;
      alpha1[d] = _roundHalfEven(f[0] * 2048);
      alpha0[d] = 2048 - alpha1[d];
    }
  }

  final Int32List offsets;
  final Int32List alpha0;
  final Int32List alpha1;
  final List<bool> interpolate;
}

int _roundHalfEven(double value) {
  final floor = value.floorToDouble();
  final diff = value - floor;
  if (diff > 0.5) return floor.toInt() + 1;
  if (diff < 0.5) return floor.toInt();
  final f = floor.toInt();
  return f.isEven ? f : f + 1;
}

/// RGBA pixels -> 1x3x640x640 float32 RGB in [0, 1].
///
/// Approximates `cv2.resize(..., INTER_LINEAR)` on 8-bit data followed by `/ 255`.
/// OpenCV on arm64 dispatches to a HAL (KleidiCV / carotene) whose rounding is not
/// reproduced here, so single values can differ by 1/255 (see README).
Float32List preprocess(Uint8List rgba, int width, int height) {
  final xt = _LinearTable(width, inputSize);
  final yt = _LinearTable(height, inputSize);
  final plane = inputSize * inputSize;
  final out = Float32List(3 * plane);
  final rows = <int, List<Int32List>>{};

  List<Int32List> hresize(int sy) => rows.putIfAbsent(sy, () {
        final channels = List.generate(3, (_) => Int32List(inputSize));
        final base = sy * width * 4;
        for (var dx = 0; dx < inputSize; dx++) {
          final sx = base + xt.offsets[dx] * 4;
          for (var c = 0; c < 3; c++) {
            channels[c][dx] = xt.interpolate[dx]
                ? rgba[sx + c] * xt.alpha0[dx] + rgba[sx + 4 + c] * xt.alpha1[dx]
                : rgba[sx + c] * 2048;
          }
        }
        return channels;
      });

  for (var dy = 0; dy < inputSize; dy++) {
    final sy = yt.offsets[dy];
    final r0 = hresize(sy);
    final r1 = hresize(math.min(sy + 1, height - 1));
    final b0 = yt.alpha0[dy];
    final b1 = yt.interpolate[dy] ? yt.alpha1[dy] : 0;
    for (var c = 0; c < 3; c++) {
      final s0 = r0[c];
      final s1 = r1[c];
      final offset = c * plane + dy * inputSize;
      for (var dx = 0; dx < inputSize; dx++) {
        // Both passes are Q11, so round once at 2^22. The sum stays below 2^31.
        final v = (b0 * s0[dx] + b1 * s1[dx] + (1 << 21)) >> 22;
        out[offset + dx] = v / 255.0;
      }
    }
    rows.removeWhere((key, _) => key < sy);
  }
  return out;
}

List<Detection> postprocess(
  Float32List logits,
  Float32List boxes,
  List<String> labels,
  int width,
  int height,
) {
  final numClasses = labels.length;
  final queries = logits.length ~/ numClasses;
  final detections = <Detection>[];
  for (var q = 0; q < queries; q++) {
    var best = -double.infinity;
    var bestClass = 0;
    for (var c = 0; c < numClasses; c++) {
      final v = logits[q * numClasses + c];
      if (v > best) {
        best = v;
        bestClass = c;
      }
    }
    final score = 1.0 / (1.0 + math.exp(-best));
    if (score < scoreThreshold) continue;
    final cx = boxes[q * 4], cy = boxes[q * 4 + 1];
    final w = boxes[q * 4 + 2], h = boxes[q * 4 + 3];
    int px(double v, int size) => _roundHalfEven(v * size).clamp(0, size - 1);
    final x1 = px(cx - w / 2, width), y1 = px(cy - h / 2, height);
    final x2 = px(cx + w / 2, width), y2 = px(cy + h / 2, height);
    if (x2 <= x1 || y2 <= y1) continue;
    detections.add(Detection(labels[bestClass], score, [x1, y1, x2, y2]));
  }
  detections.sort((a, b) => b.score.compareTo(a.score));
  return detections;
}

double maxAbsDiff(Float32List a, Float32List b) {
  if (a.length != b.length) return double.nan;
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > m) m = d;
  }
  return m;
}

int countDifferent(Float32List a, Float32List b) {
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) n++;
  }
  return n;
}
