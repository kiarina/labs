import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../image/resize.dart';
import '../image/rgb_image.dart';
import '../onnx.dart';

/// One detection, as kiarina's `DetectedObject`: [bbox] is normalized
/// [x1, y1, x2, y2], [keypoints] normalized (x, y).
class Detection {
  Detection({required this.bbox, required this.score, required this.label, this.keypoints = const [], this.keypointsPx = const []});

  final List<double> bbox;
  final double score;
  final String label;
  final List<List<double>> keypoints;

  /// The same keypoints in input pixels (faces: used for alignment).
  final List<List<double>> keypointsPx;

  Map<String, Object?> toJson() => {
        'bbox': bbox,
        'score': score,
        'label': label,
        if (keypoints.isNotEmpty) 'keypoints': keypoints,
      };
}

// ---------------------------------------------------------------- YuNet

/// YuNet face detection, decoded as OpenCV's FaceDetectorYN does
/// (tools/ref_yunet.py): BGR 0..255 input zero-padded to a multiple of 32,
/// scores sqrt(cls * obj), boxes and 5 landmarks per stride 8/16/32, then
/// NMS on integer boxes.
class YuNet {
  YuNet(this.model, {this.scoreThreshold = 0.9, this.nmsThreshold = 0.3, this.topK = 5000});

  final OnnxModel model;
  final double scoreThreshold;
  final double nmsThreshold;
  final int topK;

  static int padSize(int n) => ((n - 1) ~/ 32 + 1) * 32;

  static Float32List blob(RgbImage image) {
    final ph = padSize(image.height), pw = padSize(image.width);
    final out = Float32List(3 * ph * pw);
    final d = image.data;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final i = (y * image.width + x) * 3;
        final o = y * pw + x;
        out[o] = d[i + 2].toDouble(); // B
        out[ph * pw + o] = d[i + 1].toDouble(); // G
        out[2 * ph * pw + o] = d[i].toDouble(); // R
      }
    }
    return out;
  }

  Future<List<Detection>> detect(RgbImage image) async {
    final ph = padSize(image.height), pw = padSize(image.width);
    final outputs = await model.run({'input': Tensor.float32(blob(image), [1, 3, ph, pw])});
    final rows = decode(outputs, ph, pw);
    final kept = nms(rows);
    return [
      for (final f in kept)
        Detection(
          bbox: [f[0] / image.width, f[1] / image.height, (f[0] + f[2]) / image.width, (f[1] + f[3]) / image.height],
          score: f[14],
          label: 'face',
          keypoints: [for (var k = 0; k < 5; k++) [f[4 + 2 * k] / image.width, f[5 + 2 * k] / image.height]],
          keypointsPx: [for (var k = 0; k < 5; k++) [f[4 + 2 * k], f[5 + 2 * k]]],
        ),
    ];
  }

  /// Rows of [x, y, w, h, 5 x (kx, ky), score], float32 like OpenCV.
  static List<Float32List> decode(Map<String, Tensor> outputs, int ph, int pw) {
    final rows = <Float32List>[];
    for (final stride in const [8, 16, 32]) {
      final cols = pw ~/ stride, nRows = ph ~/ stride;
      final cls = outputs['cls_$stride']!.float32;
      final obj = outputs['obj_$stride']!.float32;
      final bbox = outputs['bbox_$stride']!.float32;
      final kps = outputs['kps_$stride']!.float32;
      for (var r = 0; r < nRows; r++) {
        for (var c = 0; c < cols; c++) {
          final i = r * cols + c;
          final row = Float32List(15);
          final clsS = cls[i].clamp(0.0, 1.0);
          final objS = obj[i].clamp(0.0, 1.0);
          // float32 product, as OpenCV computes it
          final prod = (Float32List(1)..[0] = clsS * objS)[0];
          row[14] = math.sqrt(prod);
          final cx = (c + bbox[i * 4]) * stride;
          final cy = (r + bbox[i * 4 + 1]) * stride;
          final w = math.exp(bbox[i * 4 + 2]) * stride;
          final h = math.exp(bbox[i * 4 + 3]) * stride;
          row[0] = cx - w / 2;
          row[1] = cy - h / 2;
          row[2] = w;
          row[3] = h;
          for (var n = 0; n < 5; n++) {
            row[4 + 2 * n] = (kps[i * 10 + 2 * n] + c) * stride;
            row[5 + 2 * n] = (kps[i * 10 + 2 * n + 1] + r) * stride;
          }
          rows.add(row);
        }
      }
    }
    return rows;
  }

  List<Float32List> nms(List<Float32List> rows) {
    final order = [for (var i = 0; i < rows.length; i++) if (rows[i][14] > scoreThreshold) i];
    order.sort((a, b) {
      final d = rows[b][14].compareTo(rows[a][14]);
      return d != 0 ? d : a.compareTo(b);
    });
    final boxes = [for (final r in rows) [r[0].truncate(), r[1].truncate(), r[2].truncate(), r[3].truncate()]];
    final keep = <int>[];
    for (final i in order.take(topK)) {
      if (keep.every((k) => _iou(boxes[i], boxes[k]) <= nmsThreshold)) keep.add(i);
    }
    return [for (final i in keep) rows[i]];
  }

  static double _iou(List<int> a, List<int> b) {
    final iw = math.min(a[0] + a[2], b[0] + b[2]) - math.max(a[0], b[0]);
    final ih = math.min(a[1] + a[3], b[1] + b[3]) - math.max(a[1], b[1]);
    final inter = iw > 0 && ih > 0 ? iw * ih : 0;
    final union = a[2] * a[3] + b[2] * b[3] - inter;
    return union > 0 ? inter / union : 0.0;
  }
}

// ---------------------------------------------------------------- D-FINE

/// D-FINE (COCO, 80 classes) as kiarina runs it: resize to 640x640 (no
/// letterbox), 0..1 RGB, sigmoid of the logits, best class per query, boxes
/// above [scoreThreshold]. No NMS (DETR-style queries).
class DFine {
  DFine(this.model, this.labels, {this.inputSize = 640, this.scoreThreshold = 0.5});

  /// Labels from the model's config.json (id2label), as kiarina builds them.
  static List<String> labelsFromConfig(String configJson) {
    final id2label = (jsonDecode(configJson) as Map<String, dynamic>)['id2label'] as Map<String, dynamic>;
    return [for (var i = 0; i < id2label.length; i++) id2label['$i'] as String];
  }

  final OnnxModel model;
  final List<String> labels;
  final int inputSize;
  final double scoreThreshold;

  Float32List input(RgbImage image) {
    final r = resizeLinear(image, inputSize, inputSize);
    final n = inputSize * inputSize;
    final out = Float32List(3 * n);
    final d = r.data;
    for (var i = 0; i < n; i++) {
      out[i] = d[i * 3] / 255.0;
      out[n + i] = d[i * 3 + 1] / 255.0;
      out[2 * n + i] = d[i * 3 + 2] / 255.0;
    }
    return out;
  }

  Future<List<Detection>> detect(RgbImage image) async {
    final outputs = await model.run(
      {'pixel_values': Tensor.float32(input(image), [1, 3, inputSize, inputSize])},
      outputs: {'logits', 'pred_boxes'},
    );
    final logits = outputs['logits']!;
    final boxes = outputs['pred_boxes']!.float32;
    final classes = logits.shape.last;
    final queries = logits.float32.length ~/ classes;
    final l = logits.float32;
    final result = <Detection>[];
    for (var q = 0; q < queries; q++) {
      var best = 0;
      var bestLogit = l[q * classes];
      for (var c = 1; c < classes; c++) {
        if (l[q * classes + c] > bestLogit) {
          bestLogit = l[q * classes + c];
          best = c;
        }
      }
      // float32 sigmoid, as numpy computes it on float32 logits
      final score = (Float32List(1)..[0] = 1.0 / (1.0 + math.exp(-bestLogit)))[0];
      if (score < scoreThreshold) continue;
      final cx = boxes[q * 4], cy = boxes[q * 4 + 1], w = boxes[q * 4 + 2], h = boxes[q * 4 + 3];
      result.add(Detection(
        bbox: [cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2],
        score: score,
        label: best < labels.length ? labels[best] : '$best',
      ));
    }
    return result;
  }
}
