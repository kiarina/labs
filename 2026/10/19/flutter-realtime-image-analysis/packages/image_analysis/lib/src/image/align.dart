import 'dart:math' as math;
import 'dart:typed_data';

import 'rgb_image.dart';

/// ArcFace 5-point template for a 112x112 aligned face (image-left eye,
/// image-right eye, nose, image-left mouth, image-right mouth), as kiarina's
/// `crop_align_faces` uses it.
const arcfaceTemplate = <List<double>>[
  [38.2946, 51.6963],
  [73.5318, 51.5014],
  [56.0252, 71.7366],
  [41.5493, 92.3655],
  [70.7299, 92.2041],
];

/// Least-squares similarity transform (Umeyama, no reflection) mapping
/// [src] points onto [dst]; a 2x3 matrix [a, b, tx, c, d, ty].
///
/// For 2-D points the similarity has a closed form; it gives the same matrix
/// as kiarina's SVD-based `_umeyama` up to rounding (~1e-13).
List<double> umeyama2d(List<List<double>> src, List<List<double>> dst) {
  final n = src.length;
  var sx = 0.0, sy = 0.0, dx = 0.0, dy = 0.0;
  for (var i = 0; i < n; i++) {
    sx += src[i][0];
    sy += src[i][1];
    dx += dst[i][0];
    dy += dst[i][1];
  }
  sx /= n;
  sy /= n;
  dx /= n;
  dy /= n;
  // covariance dst^T src / n, and the source variance
  var a = 0.0, b = 0.0, c = 0.0, d = 0.0, varSrc = 0.0;
  for (var i = 0; i < n; i++) {
    final px = src[i][0] - sx, py = src[i][1] - sy;
    final qx = dst[i][0] - dx, qy = dst[i][1] - dy;
    a += qx * px;
    b += qx * py;
    c += qy * px;
    d += qy * py;
    varSrc += px * px + py * py;
  }
  a /= n;
  b /= n;
  c /= n;
  d /= n;
  varSrc /= n;
  // best rotation: angle of (a + d, c - b); scale: |(a + d, c - b)| / var
  final p = a + d;
  final q = c - b;
  final norm = math.sqrt(p * p + q * q);
  final cosT = p / norm;
  final sinT = q / norm;
  final scale = norm / varSrc;
  final m00 = scale * cosT, m01 = -scale * sinT;
  final m10 = scale * sinT, m11 = scale * cosT;
  return [m00, m01, dx - (m00 * sx + m01 * sy), m10, m11, dy - (m10 * sx + m11 * sy)];
}

/// Inverts a 2x3 affine matrix the way OpenCV's invertAffineTransform does.
List<double> invertAffine(List<double> m) {
  var det = m[0] * m[4] - m[1] * m[3];
  det = det != 0 ? 1.0 / det : 0.0;
  final a11 = m[4] * det, a22 = m[0] * det;
  final a12 = -m[1] * det, a21 = -m[3] * det;
  final b1 = -a11 * m[2] - a12 * m[5];
  final b2 = -a21 * m[2] - a22 * m[5];
  return [a11, a12, b1, a21, a22, b2];
}

/// Bilinear warp in double precision, rounded half to even, neighbours
/// outside the image count as 0 (tools/ref_warp.py).
RgbImage warpAffine(RgbImage src, List<double> m, int dw, int dh) {
  final im = invertAffine(m);
  final s = src.data;
  final sw = src.width;
  final sh = src.height;
  final out = Uint8List(dw * dh * 3);
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      final fxp = im[0] * x + im[1] * y + im[2];
      final fyp = im[3] * x + im[4] * y + im[5];
      final x0 = fxp.floor();
      final y0 = fyp.floor();
      final fx = fxp - x0;
      final fy = fyp - y0;
      final w00 = (1 - fy) * (1 - fx), w01 = (1 - fy) * fx, w10 = fy * (1 - fx), w11 = fy * fx;
      for (var c = 0; c < 3; c++) {
        double v(int px, int py) => (px >= 0 && px < sw && py >= 0 && py < sh) ? s[(py * sw + px) * 3 + c].toDouble() : 0.0;
        var acc = 0.0;
        acc += v(x0, y0) * w00;
        acc += v(x0 + 1, y0) * w01;
        acc += v(x0, y0 + 1) * w10;
        acc += v(x0 + 1, y0 + 1) * w11;
        out[(y * dw + x) * 3 + c] = roundHalfEven(acc).clamp(0, 255);
      }
    }
  }
  return RgbImage(dw, dh, out);
}

/// kiarina's `crop_align_faces` for one face: [keypoints] are 5 normalized
/// (x, y) points; the result is [size] x [size].
RgbImage alignFace(RgbImage image, List<List<double>> keypoints, {int size = 112}) =>
    alignFacePixels(image, [for (final k in keypoints) [k[0] * image.width, k[1] * image.height]], size: size);

/// The same from keypoints in pixels (what the detector produced, before
/// normalizing; avoids a round trip through x / width * width).
RgbImage alignFacePixels(RgbImage image, List<List<double>> src, {int size = 112}) {
  final dst = [for (final p in arcfaceTemplate) [p[0] * size / 112.0, p[1] * size / 112.0]];
  return warpAffine(image, umeyama2d(src, dst), size, size);
}
