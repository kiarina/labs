import 'dart:math' as math;
import 'dart:typed_data';

/// Samples of a 16-bit PCM mono WAV (the files made by `mise run prepare`).
Int16List wavSamples(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      final n = size ~/ 2;
      final out = Int16List(n);
      for (var i = 0; i < n; i++) {
        out[i] = data.getInt16(offset + 8 + i * 2, Endian.little);
      }
      return out;
    }
    offset += 8 + size + (size & 1);
  }
  throw const FormatException('no data chunk');
}

double rms(Int16List samples, [int start = 0, int? end]) {
  final e = math.min(end ?? samples.length, samples.length);
  final s = math.max(0, start);
  if (e <= s) return 0;
  var sum = 0.0;
  for (var i = s; i < e; i++) {
    sum += samples[i] * samples[i].toDouble();
  }
  return math.sqrt(sum / (e - s)) / 32768;
}

/// dBFS of an RMS value; null for digital silence (JSON has no -Infinity).
double? db(double ratio) =>
    ratio <= 0 ? null : 20 * math.log(ratio) / math.ln10;

/// Rectified envelope at 1 kHz (one value per millisecond).
Float64List envelope(Int16List x, int sampleRate) {
  final step = sampleRate ~/ 1000;
  final out = Float64List(x.length ~/ step);
  for (var i = 0; i < out.length; i++) {
    var acc = 0.0;
    for (var k = 0; k < step; k++) {
      acc += x[i * step + k].abs();
    }
    out[i] = acc / step / 32768;
  }
  return out;
}

/// How much of [reference] is in [recorded]: the best normalized
/// cross-correlation of the 1 kHz envelopes over lags [minLagMs]..[maxLagMs]
/// (reference shifted later in the recording by the lag). Envelopes make the
/// search cheap and tolerant of resampling drift; 1 means the reference is in
/// the recording unchanged in shape, ~0.1 is what unrelated sound gives.
({double peak, int lagMs}) envelopeCorrelation(
  Float64List ref,
  Float64List rec, {
  int minLagMs = 0,
  int maxLagMs = 800,
}) {
  final n = ref.length;
  var best = 0.0;
  var bestLag = 0;
  for (var lag = minLagMs; lag <= maxLagMs; lag++) {
    // Overlap of ref[i] with rec[lag + i].
    final i0 = math.max(0, -lag);
    final i1 = math.min(n, rec.length - lag);
    if (i1 - i0 < n ~/ 2) continue;
    var recMean = 0.0;
    var a0 = 0.0;
    for (var i = i0; i < i1; i++) {
      recMean += rec[lag + i];
      a0 += ref[i];
    }
    recMean /= (i1 - i0);
    a0 /= (i1 - i0);
    var cov = 0.0;
    var rv = 0.0;
    var fv = 0.0;
    for (var i = i0; i < i1; i++) {
      final a = ref[i] - a0;
      final b = rec[lag + i] - recMean;
      cov += a * b;
      rv += b * b;
      fv += a * a;
    }
    if (rv == 0 || fv == 0) continue;
    final c = cov / math.sqrt(fv * rv);
    if (c > best) {
      best = c;
      bestLag = lag;
    }
  }
  return (peak: best, lagMs: bestLag);
}
