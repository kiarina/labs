import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_analysis/audio_analysis.dart';

/// Shared by decoded file audio and microphone audio, including web.
class PcmAnalysis {
  PcmAnalysis(OnnxModel model)
    : detector = VoiceDetector(
        SileroVad(model),
        settings: const VoiceDetectorSettings(
          minSilenceMs: 300,
          maxVoiceMs: 8000,
        ),
      );
  final VoiceDetector detector;
  final List<double> _pending = [];
  final List<Map<String, Object>> voices = [];
  int samples = 0, chunks = 0, positive = 0, bytes = 0;
  double energy = 0, peak = 0;
  int? _odd;
  final Stopwatch compute = Stopwatch();
  Future<void> add(Uint8List input) async {
    // Stream callbacks need not align with a sample or a VAD frame.
    final data = _odd == null ? input : Uint8List.fromList([_odd!, ...input]);
    _odd = data.length.isOdd ? data.last : null;
    final view = ByteData.sublistView(data);
    bytes += input.length;
    for (var i = 0; i + 1 < data.length; i += 2) {
      final v = view.getInt16(i, Endian.little) / 32768;
      samples++;
      energy += v * v;
      peak = math.max(peak, v.abs());
      _pending.add(v);
    }
    while (_pending.length >= 512) {
      final x = Float32List.fromList(_pending.sublist(0, 512));
      _pending.removeRange(0, 512);
      compute.start();
      final r = await detector.detect(x, 16000, chunks * 512 / 16000);
      compute.stop();
      chunks++;
      if (r.isVoice) positive++;
      if (r.voice != null) _voice(r.voice!);
    }
  }

  void _voice(Voice v) =>
      voices.add({'start': v.startTimestamp, 'end': v.endTimestamp});
  void finish() {
    final v = detector.flush();
    if (v != null) _voice(v);
  }

  Map<String, Object> report() => {
    'samples': samples,
    'seconds': samples / 16000,
    'rms': samples == 0 ? 0 : math.sqrt(energy / samples),
    'peak': peak,
    'vad_chunks': chunks,
    'vad_positive': positive,
    'vad_ms': compute.elapsedMicroseconds / 1000,
    'voices': voices,
    'tail_samples': _pending.length,
    'dangling_byte': _odd != null,
  };
}

/// Minimal image consumer shared by both backends: validates JPEG dimensions
/// and monotonic source presentation timestamps without retaining media.
class FrameAnalysis {
  final frames = <Map<String, Object>>[];
  Future<void> add(Uint8List jpeg, double pts) async {
    if (jpeg.length < 4 || jpeg[0] != 255 || jpeg[1] != 216)
      throw FormatException('Not a JPEG');
    if (frames.isNotEmpty && pts <= (frames.last['pts'] as double))
      throw StateError('Non-monotonic frame');
    final b = ByteData.sublistView(jpeg);
    var i = 2;
    while (i + 3 < jpeg.length) {
      if (jpeg[i++] != 255) continue;
      final marker = jpeg[i++];
      if (marker == 255) {
        i--;
        continue;
      }
      if (marker == 0xd9 || marker == 0xda) break;
      if (marker >= 0xd0 && marker <= 0xd7) continue;
      final size = b.getUint16(i);
      if (size < 2 || i + size > jpeg.length)
        throw FormatException('Broken JPEG segment');
      if ([0xc0, 0xc1, 0xc2].contains(marker)) {
        frames.add({
          'pts': pts,
          'width': b.getUint16(i + 5),
          'height': b.getUint16(i + 3),
          'bytes': jpeg.length,
        });
        return;
      }
      i += size;
    }
    throw FormatException('JPEG has no supported SOF');
  }
}
