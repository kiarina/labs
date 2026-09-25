import 'dart:math' as math;
import 'dart:typed_data';

export 'camera_probe_native.dart'
    if (dart.library.js_interop) 'camera_probe_web.dart';

/// Frame delivery statistics shared by the native (`camera`) and web probes.
final class FrameStats {
  /// Starts at the first frame's arrival check, so permission prompts and
  /// camera start-up do not count.
  final Stopwatch clock = Stopwatch()..start();
  int frames = 0;
  int? width;
  int? height;
  String? format;
  int? planes;
  Duration? firstAt;
  Duration? lastAt;
  Duration maxGap = Duration.zero;
  final List<int> convertUs = [];
  int converted = 0;
  Duration? lastConvertAt;
  double lumaMean = 0;

  /// Returns true when this frame should be converted (rate limiting).
  bool onFrame(int w, int h, String fmt, int planeCount, Duration interval) {
    final now = clock.elapsed;
    if (lastAt != null && now - lastAt! > maxGap) maxGap = now - lastAt!;
    firstAt ??= now;
    lastAt = now;
    frames++;
    width = w;
    height = h;
    format = fmt;
    planes = planeCount;
    if (lastConvertAt != null && now - lastConvertAt! < interval) return false;
    lastConvertAt = now;
    return true;
  }

  void recordConversion(int us, Uint8List rgb) {
    converted++;
    if (convertUs.length < 10000) convertUs.add(us);
    var sum = 0;
    for (var i = 1; i < rgb.length; i += 3) {
      sum += rgb[i];
    }
    lumaMean = sum / (rgb.length / 3);
  }

  Map<String, Object?> toJson() {
    final span = (firstAt != null && lastAt != null)
        ? (lastAt! - firstAt!).inMicroseconds / 1e6
        : 0.0;
    final sorted = [...convertUs]..sort();
    double? pct(double p) => sorted.isEmpty
        ? null
        : sorted[((sorted.length - 1) * p).round()] / 1000;
    return {
      'frames': frames,
      'fps': span > 0 ? (frames - 1) / span : null,
      'width': width,
      'height': height,
      'format': format,
      'planes': planes,
      'firstFrameMs': firstAt?.inMilliseconds,
      'maxGapMs': maxGap.inMicroseconds / 1000,
      'converted': converted,
      'convertedPerSecond': span > 0 ? converted / span : null,
      'convertP50Ms': pct(0.5),
      'convertP95Ms': pct(0.95),
      'convertMaxMs': pct(1),
      'rgbGreenMean': lumaMean,
    };
  }
}

/// Nearest-neighbour conversion of a BGRA/RGBA buffer to packed RGB at
/// [outWidth] (height keeps the aspect ratio).
Uint8List rgbFrom4Channel(
  Uint8List src,
  int w,
  int h,
  int stride,
  int outWidth, {
  required bool bgra,
}) {
  final ow = math.min(outWidth, w);
  final oh = h * ow ~/ w;
  final out = Uint8List(ow * oh * 3);
  final r = bgra ? 2 : 0;
  final b = bgra ? 0 : 2;
  var o = 0;
  for (var y = 0; y < oh; y++) {
    final row = (y * h ~/ oh) * stride;
    for (var x = 0; x < ow; x++) {
      final p = row + (x * w ~/ ow) * 4;
      out[o++] = src[p + r];
      out[o++] = src[p + 1];
      out[o++] = src[p + b];
    }
  }
  return out;
}

/// Nearest-neighbour YUV 4:2:0 (planar or semi-planar) to packed RGB.
Uint8List rgbFromYuv420(
  Uint8List y,
  int yStride,
  Uint8List u,
  Uint8List v,
  int uvStride,
  int uvPixelStride,
  int w,
  int h,
  int outWidth,
) {
  final ow = math.min(outWidth, w);
  final oh = h * ow ~/ w;
  final out = Uint8List(ow * oh * 3);
  var o = 0;
  for (var oy = 0; oy < oh; oy++) {
    final sy = oy * h ~/ oh;
    final yRow = sy * yStride;
    final uvRow = (sy >> 1) * uvStride;
    for (var ox = 0; ox < ow; ox++) {
      final sx = ox * w ~/ ow;
      final yy = y[yRow + sx] - 16;
      final uvi = uvRow + (sx >> 1) * uvPixelStride;
      final uu = u[uvi] - 128;
      final vv = v[uvi] - 128;
      final c = 298 * yy;
      out[o++] = ((c + 409 * vv + 128) >> 8).clamp(0, 255);
      out[o++] = ((c - 100 * uu - 208 * vv + 128) >> 8).clamp(0, 255);
      out[o++] = ((c + 516 * uu + 128) >> 8).clamp(0, 255);
    }
  }
  return out;
}
