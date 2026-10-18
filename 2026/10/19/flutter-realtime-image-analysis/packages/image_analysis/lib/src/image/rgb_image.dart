import 'dart:typed_data';

/// An 8-bit RGB image, rows top to bottom, no padding.
class RgbImage {
  RgbImage(this.width, this.height, this.data) : assert(data.length == width * height * 3);

  RgbImage.zeros(this.width, this.height) : data = Uint8List(width * height * 3);

  /// From a camera frame: BGRA rows, [bytesPerRow] may include padding.
  factory RgbImage.fromBgra(int width, int height, int bytesPerRow, Uint8List bgra) {
    final out = Uint8List(width * height * 3);
    var o = 0;
    for (var y = 0; y < height; y++) {
      var i = y * bytesPerRow;
      for (var x = 0; x < width; x++, i += 4) {
        out[o++] = bgra[i + 2];
        out[o++] = bgra[i + 1];
        out[o++] = bgra[i];
      }
    }
    return RgbImage(width, height, out);
  }

  final int width;
  final int height;
  final Uint8List data;

  /// Pixels [x1, x2) x [y1, y2), clamped to the image.
  RgbImage crop(int x1, int y1, int x2, int y2) {
    x1 = x1.clamp(0, width);
    x2 = x2.clamp(0, width);
    y1 = y1.clamp(0, height);
    y2 = y2.clamp(0, height);
    if (x2 < x1) (x1, x2) = (x2, x1);
    if (y2 < y1) (y1, y2) = (y2, y1);
    final w = x2 - x1;
    final h = y2 - y1;
    final out = Uint8List(w * h * 3);
    for (var y = 0; y < h; y++) {
      final s = ((y1 + y) * width + x1) * 3;
      out.setRange(y * w * 3, (y + 1) * w * 3, data, s);
    }
    return RgbImage(w, h, out);
  }

  /// A crop from a normalized [x1, y1, x2, y2] box, rounded the way
  /// kiarina's `crop_objects` rounds (Python's round: half to even).
  RgbImage cropNormalized(List<double> bbox) => crop(
        roundHalfEven(bbox[0] * width),
        roundHalfEven(bbox[1] * height),
        roundHalfEven(bbox[2] * width),
        roundHalfEven(bbox[3] * height),
      );
}

/// Round half to even, like Python's round(), numpy's rint and C's lrint.
int roundHalfEven(double v) {
  final f = v.floorToDouble();
  final d = v - f;
  if (d > 0.5) return f.toInt() + 1;
  if (d < 0.5) return f.toInt();
  final i = f.toInt();
  return i.isEven ? i : i + 1;
}
