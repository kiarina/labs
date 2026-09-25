import 'dart:math' as math;
import 'dart:typed_data';

/// Echo test signal: speech-band chirps (300 Hz → 3.4 kHz, 250 ms each, 50 ms
/// gaps). Non-stationary on purpose: noise suppressors remove steady tones,
/// which would make a tone test measure the suppressor instead of the echo
/// canceller.
Float64List echoTestSignal({
  required int sampleRate,
  Duration duration = const Duration(seconds: 4),
  double amplitude = 0.5,
}) {
  final n = (sampleRate * duration.inMicroseconds / 1e6).round();
  final out = Float64List(n);
  final chirp = (sampleRate * 0.25).round();
  final period = (sampleRate * 0.30).round();
  const f0 = 300.0;
  const f1 = 3400.0;
  for (var i = 0; i < n; i++) {
    final j = i % period;
    if (j >= chirp) continue;
    final t = j / sampleRate;
    const tChirp = 0.25;
    // Linear chirp phase, with a short fade to avoid clicks.
    final phase = 2 * math.pi * (f0 * t + (f1 - f0) * t * t / (2 * tChirp));
    final fade = math.min(1.0, math.min(j, chirp - j) / (sampleRate * 0.005));
    out[i] = amplitude * fade * math.sin(phase);
  }
  return out;
}

/// 16-bit mono WAV with [lead] and [tail] of silence around [signal].
Uint8List wavBytes(
  Float64List signal, {
  required int sampleRate,
  Duration lead = Duration.zero,
  Duration tail = Duration.zero,
}) {
  final leadN = (sampleRate * lead.inMicroseconds / 1e6).round();
  final tailN = (sampleRate * tail.inMicroseconds / 1e6).round();
  final total = leadN + signal.length + tailN;
  final data = ByteData(44 + total * 2);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + total * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, total * 2, Endian.little);
  for (var i = 0; i < signal.length; i++) {
    final v = (signal[i] * 32767).round().clamp(-32768, 32767);
    data.setInt16(44 + (leadN + i) * 2, v, Endian.little);
  }
  return data.buffer.asUint8List();
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

/// How much of [reference] (played through the speaker) is in [recorded].
///
/// Returns the best normalized cross-correlation over lags 0..[maxLag] (the
/// playback + capture latency is unknown), computed on 1 kHz envelopes of the
/// signals so the search is cheap and robust to small resampling drift.
({double peak, int lagMs}) echoCorrelation(
  Float64List reference,
  Int16List recorded, {
  required int sampleRate,
  int maxLagMs = 600,
}) {
  // Rectified envelope at 1 kHz.
  Float64List envelope(List<num> x, double scale) {
    final step = sampleRate ~/ 1000;
    final out = Float64List(x.length ~/ step);
    for (var i = 0; i < out.length; i++) {
      var acc = 0.0;
      for (var k = 0; k < step; k++) {
        acc += (x[i * step + k] * scale).abs();
      }
      out[i] = acc / step;
    }
    return out;
  }

  final ref = envelope(reference, 1);
  final rec = envelope(recorded, 1 / 32768);
  double mean(Float64List v, int s, int n) {
    var a = 0.0;
    for (var i = 0; i < n; i++) {
      a += v[s + i];
    }
    return a / n;
  }

  final n = ref.length;
  final refMean = mean(ref, 0, n);
  var refVar = 0.0;
  for (var i = 0; i < n; i++) {
    refVar += (ref[i] - refMean) * (ref[i] - refMean);
  }
  var best = 0.0;
  var bestLag = 0;
  for (var lag = 0; lag <= maxLagMs && lag + n <= rec.length; lag++) {
    final recMean = mean(rec, lag, n);
    var cov = 0.0;
    var recVar = 0.0;
    for (var i = 0; i < n; i++) {
      final a = ref[i] - refMean;
      final b = rec[lag + i] - recMean;
      cov += a * b;
      recVar += b * b;
    }
    if (recVar == 0 || refVar == 0) continue;
    final c = cov / math.sqrt(refVar * recVar);
    if (c > best) {
      best = c;
      bestLag = lag;
    }
  }
  return (peak: best, lagMs: bestLag);
}
