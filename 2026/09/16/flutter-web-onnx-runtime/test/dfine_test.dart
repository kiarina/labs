import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_onnx_dfine/dfine.dart';

void main() {
  test('preprocess keeps a uniform image uniform and normalizes to [0, 1]', () {
    const width = 1536, height = 1024;
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 255;
      rgba[i + 1] = 51;
      rgba[i + 2] = 0;
      rgba[i + 3] = 255;
    }
    final out = preprocess(rgba, width, height);
    final plane = inputSize * inputSize;
    expect(out.length, 3 * plane);
    expect(out.sublist(0, plane).every((v) => v == 1.0), isTrue);
    final green = (Float32List(1)..[0] = 51 / 255)[0];
    expect(out.sublist(plane, 2 * plane).every((v) => v == green), isTrue);
    expect(out.sublist(2 * plane).every((v) => v == 0.0), isTrue);
  });

  test('postprocess thresholds, maps boxes to pixels, and sorts by score', () {
    final labels = ['a', 'b'];
    // 3 queries x 2 classes. sigmoid(2.0) = 0.88, sigmoid(0.5) = 0.62, sigmoid(-1) = 0.27
    final logits = Float32List.fromList([-5, 0.5, 2.0, -5, -1, -1]);
    final boxes = Float32List.fromList([
      0.5, 0.5, 0.2, 0.2, //
      0.25, 0.25, 0.5, 0.5, //
      0.5, 0.5, 1.0, 1.0,
    ]);
    final detections = postprocess(logits, boxes, labels, 100, 200);
    expect(detections.map((d) => d.label), ['a', 'b']);
    expect(detections[0].bbox, [0, 0, 50, 100]);
    expect(detections[1].bbox, [40, 80, 60, 120]);
  });
}
