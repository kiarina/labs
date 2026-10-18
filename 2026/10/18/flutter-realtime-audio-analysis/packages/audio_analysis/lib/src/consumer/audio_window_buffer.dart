import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pcm.dart';

class AudioWindow {
  AudioWindow(this.samples, this.sampleRate, this.start, this.end);

  final Float32List samples;
  final int sampleRate;
  final double start;
  final double end;
}

/// Port of kiarina's `AudioWindowBuffer` (fixed windows, remainder on flush).
class AudioWindowBuffer {
  AudioWindowBuffer({required this.windowSeconds});

  final double windowSeconds;
  int? _sampleRate;
  int? _window;
  final List<Float32List> _parts = [];
  int _length = 0;
  double? _start;

  void reset() {
    _parts.clear();
    _length = 0;
    _start = null;
  }

  List<AudioWindow> accept(Float32List samples, int sampleRate, double timestamp) {
    if (_sampleRate == null) {
      _sampleRate = sampleRate;
      _window = math.max(1, pyRound(windowSeconds * sampleRate));
    } else if (_sampleRate != sampleRate) {
      throw StateError('AudioWindowBuffer expects a stable sample rate');
    }
    if (_length == 0) _start = timestamp;
    _parts.add(samples);
    _length += samples.length;
    return _drain(fullOnly: true);
  }

  List<AudioWindow> flush() => _drain(fullOnly: false);

  List<AudioWindow> _drain({required bool fullOnly}) {
    final out = <AudioWindow>[];
    if (_start == null || _window == null) return out;
    while (_length > 0) {
      if (fullOnly && _length < _window!) break;
      final all = concatFloat32(_parts);
      final n = math.min(_window!, all.length);
      final samples = Float32List.fromList(all.sublist(0, n));
      final end = _start! + n / _sampleRate!;
      out.add(AudioWindow(samples, _sampleRate!, _start!, end));
      _parts
        ..clear()
        ..add(Float32List.fromList(all.sublist(n)));
      _length = all.length - n;
      _start = end;
    }
    if (_length == 0) _parts.clear();
    return out;
  }
}
