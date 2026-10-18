import 'dart:math' as math;
import 'dart:typed_data';

/// In-place iterative radix-2 complex FFT (double precision, like numpy's
/// pocketfft on float32 input). [n] must be a power of two.
class Fft {
  Fft(this.n)
      : assert(n > 0 && (n & (n - 1)) == 0),
        _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Int32List(n) {
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(-2 * math.pi * i / n);
      _sin[i] = math.sin(-2 * math.pi * i / n);
    }
    final bits = (math.log(n) / math.ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  final int n;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;

  /// Power spectrum |rfft(frame)|^2 for bins 0..n/2 written into [out].
  void powerSpectrum(Float64List frame, Float64List re, Float64List im, Float64List out) {
    for (var i = 0; i < n; i++) {
      re[_rev[i]] = frame[i];
      im[_rev[i]] = 0;
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = _sin[k * step];
          final a = start + k, b = a + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
    for (var k = 0; k <= n ~/ 2; k++) {
      out[k] = re[k] * re[k] + im[k] * im[k];
    }
  }
}
