import 'dart:math' as math;
import 'dart:typed_data';

/// PCM16 little-endian bytes to float32 samples in [-1, 1).
Float32List pcm16ToFloat32(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Linear resampling identical to kiarina's `np.interp` over `np.linspace`
/// positions (`_resample` in the Python providers).
Float32List resampleLinear(
  Float32List samples,
  int sourceRate,
  int targetRate,
) {
  if (sourceRate == targetRate || samples.isEmpty) return samples;
  final duration = samples.length / sourceRate;
  final targetLength = math.max(1, _roundHalfEven(duration * targetRate));
  final out = Float32List(targetLength);
  final last = samples.length - 1;
  if (last == 0 || targetLength == 1) {
    out.fillRange(0, targetLength, samples[0]);
    return out;
  }
  // np.linspace(0, last, num) -> i * last / (num - 1); source positions are integers.
  final step = last / (targetLength - 1);
  for (var i = 0; i < targetLength; i++) {
    final pos = i == targetLength - 1 ? last.toDouble() : i * step;
    final i0 = pos.floor();
    if (i0 >= last) {
      out[i] = samples[last];
      continue;
    }
    final frac = pos - i0;
    out[i] = samples[i0] + (samples[i0 + 1] - samples[i0]) * frac;
  }
  return out;
}

/// Python's `round()` (banker's rounding).
int _roundHalfEven(double value) {
  final floor = value.floorToDouble();
  final diff = value - floor;
  if (diff > 0.5) return floor.toInt() + 1;
  if (diff < 0.5) return floor.toInt();
  return floor.toInt().isEven ? floor.toInt() : floor.toInt() + 1;
}

int pyRound(double value) => _roundHalfEven(value);

Float32List concatFloat32(List<Float32List> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Float32List(total);
  var offset = 0;
  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }
  return out;
}

double rms(Float32List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s;
  }
  return math.sqrt(sum / samples.length);
}

Float32List l2Normalize(Float32List v) {
  var sum = 0.0;
  for (final x in v) {
    sum += x * x;
  }
  final norm = math.sqrt(sum);
  if (norm == 0) return v;
  return Float32List.fromList([for (final x in v) x / norm]);
}

double cosineSimilarity(Float32List a, Float32List b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}
