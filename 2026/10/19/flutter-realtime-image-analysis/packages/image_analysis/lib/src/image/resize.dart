import 'dart:typed_data';

import 'rgb_image.dart';

const _coefBits = 11;
const _coefScale = 1 << _coefBits;

/// cv2.resize(INTER_LINEAR) for 8-bit images, OpenCV's generic path: 11-bit
/// fixed-point weights and the rounding of its 8-bit vertical pass. An exact
/// 2x downscale becomes a 2x2 average, as OpenCV does. (tools/ref_resize.py
/// is the same arithmetic in numpy.)
RgbImage resizeLinear(RgbImage src, int dw, int dh) {
  final sw = src.width;
  final sh = src.height;
  if (sw == dw * 2 && sh == dh * 2) return _area2x(src, dw, dh);

  final (xofs, a0, a1) = _coeffs(sw, dw);
  final (yofs, b0, b1) = _coeffs(sh, dh);
  final s = src.data;

  // Horizontal pass, only for the source rows the vertical pass needs.
  final rows = <int, Int32List>{};
  Int32List row(int y) => rows.putIfAbsent(y, () {
        final r = Int32List(dw * 3);
        final base = y * sw * 3;
        for (var x = 0; x < dw; x++) {
          final p0 = base + xofs[x] * 3;
          final x1 = xofs[x] + 1 < sw ? xofs[x] + 1 : sw - 1;
          final p1 = base + x1 * 3;
          for (var c = 0; c < 3; c++) {
            r[x * 3 + c] = s[p0 + c] * a0[x] + s[p1 + c] * a1[x];
          }
        }
        return r;
      });

  final out = Uint8List(dw * dh * 3);
  for (var y = 0; y < dh; y++) {
    final y1 = yofs[y] + 1 < sh ? yofs[y] + 1 : sh - 1;
    final r0 = row(yofs[y]);
    final r1 = row(y1);
    final bb0 = b0[y];
    final bb1 = b1[y];
    final o = y * dw * 3;
    for (var i = 0; i < dw * 3; i++) {
      final v = (((bb0 * (r0[i] >> 4)) >> 16) + ((bb1 * (r1[i] >> 4)) >> 16) + 2) >> 2;
      out[o + i] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
    // rows only ever move down; drop the ones behind
    rows.removeWhere((k, _) => k < yofs[y]);
  }
  return RgbImage(dw, dh, out);
}

(Int32List, Int32List, Int32List) _coeffs(int src, int dst) {
  final scale = src / dst;
  final ofs = Int32List(dst);
  final c0 = Int32List(dst);
  final c1 = Int32List(dst);
  for (var d = 0; d < dst; d++) {
    var f = (d + 0.5) * scale - 0.5;
    var s = f.floor();
    f -= s;
    if (s < 0) {
      f = 0;
      s = 0;
    }
    if (s >= src - 1) {
      f = 0;
      s = src - 1;
    }
    ofs[d] = s;
    c0[d] = _saturateShort((1.0 - f) * _coefScale);
    c1[d] = _saturateShort(f * _coefScale);
  }
  return (ofs, c0, c1);
}

int _saturateShort(double v) => roundHalfEven(v).clamp(-32768, 32767);

RgbImage _area2x(RgbImage src, int dw, int dh) {
  final s = src.data;
  final sw = src.width;
  final out = Uint8List(dw * dh * 3);
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      final p = ((2 * y) * sw + 2 * x) * 3;
      final q = p + sw * 3;
      for (var c = 0; c < 3; c++) {
        out[(y * dw + x) * 3 + c] = (s[p + c] + s[p + 3 + c] + s[q + c] + s[q + 3 + c] + 2) >> 2;
      }
    }
  }
  return RgbImage(dw, dh, out);
}
