import 'dart:typed_data';

import '../dsp/pcm.dart';
import 'silero_vad.dart';

class Voice {
  Voice({
    required this.samples,
    required this.sampleRate,
    required this.startTimestamp,
    required this.endTimestamp,
  });

  final Float32List samples;
  final int sampleRate;
  final double startTimestamp;
  final double endTimestamp;
}

class VoiceDetectResult {
  VoiceDetectResult(this.isVoice, this.probability, this.voice);

  final bool isVoice;
  final double probability;
  final Voice? voice;
}

class VoiceDetectorSettings {
  const VoiceDetectorSettings({
    this.threshold = 0.5,
    this.minSilenceMs = 500,
    this.voicePadMs = 300,
    this.maxVoiceMs,
  });

  final double threshold;
  final int minSilenceMs;
  final int voicePadMs;

  /// Not in kiarina: emit a voice once it is this long even without a
  /// pause, so continuous talk still produces results in real time.
  /// null = unlimited (kiarina's behaviour).
  final int? maxVoiceMs;
}

class _Item {
  _Item(this.start, this.timestamp, this.samples);

  final int start;
  final double timestamp;
  final Float32List samples;
}

/// Port of kiarina's `VoiceDetector`: groups VAD-positive chunks into voices
/// with padding and a minimum trailing silence.
class VoiceDetector {
  VoiceDetector(this.vad, {this.settings = const VoiceDetectorSettings()});

  final SileroVad vad;
  final VoiceDetectorSettings settings;

  bool inVoice = false;
  int? _sampleRate;
  int _cursor = 0;
  int? _voiceStart;
  int? _lastVoiceEnd;
  int _silence = 0;
  List<_Item> _pre = [];
  List<_Item> _voice = [];

  int get sampleRate => _sampleRate!;

  /// Drops any partial voice and the VAD state (mic switched or stopped
  /// without flushing).
  void reset() {
    vad.reset();
    inVoice = false;
    _cursor = 0;
    _voiceStart = null;
    _lastVoiceEnd = null;
    _silence = 0;
    _pre = [];
    _voice = [];
  }

  Future<VoiceDetectResult> detect(Float32List samples, int sampleRate, double timestamp) async {
    _sampleRate = sampleRate;
    final prob = await vad.predict(samples, sampleRate);
    final isVoice = prob >= settings.threshold;
    final voice = _accept(samples, timestamp, prob);
    return VoiceDetectResult(isVoice, prob, voice);
  }

  Voice? flush() => inVoice ? _emit() : null;

  Voice? _accept(Float32List samples, double timestamp, double prob) {
    final chunkStart = _cursor;
    final chunkEnd = chunkStart + samples.length;
    _cursor = chunkEnd;

    if (prob >= settings.threshold) {
      if (!inVoice) {
        inVoice = true;
        _voiceStart = _pre.isNotEmpty ? _pre.first.start : chunkStart;
        _voice = [..._pre];
        _pre = [];
      }
      _voice.add(_Item(chunkStart, timestamp, samples));
      _lastVoiceEnd = chunkEnd;
      _silence = 0;
      if (settings.maxVoiceMs != null && chunkEnd - _voiceStart! >= _ms(settings.maxVoiceMs!)) {
        // cut without trailing pad; the next voiced chunk starts a new voice
        return _emit(padMs: 0);
      }
      return null;
    }

    if (!inVoice) {
      _pre.add(_Item(chunkStart, timestamp, samples));
      final minStart = _cursor - _ms(settings.voicePadMs);
      _pre = _pre.where((i) => i.start >= minStart).toList();
      return null;
    }

    _silence += samples.length;
    final pad = _ms(settings.voicePadMs);
    if (_lastVoiceEnd != null && chunkStart < _lastVoiceEnd! + pad) {
      _voice.add(_Item(chunkStart, timestamp, samples));
    }
    if (_silence >= _ms(settings.minSilenceMs)) return _emit();
    return null;
  }

  Voice _emit({int? padMs}) {
    final samples = concatFloat32([for (final i in _voice) i.samples]);
    final start = _voiceStart ?? 0;
    var end = _lastVoiceEnd ?? _cursor;
    end = (end + _ms(padMs ?? settings.voicePadMs)).clamp(0, _cursor);
    final voice = Voice(
      samples: samples,
      sampleRate: sampleRate,
      startTimestamp: _toTimestamp(start),
      endTimestamp: _toTimestamp(end),
    );
    inVoice = false;
    _voiceStart = null;
    _lastVoiceEnd = null;
    _silence = 0;
    _pre = [];
    _voice = [];
    return voice;
  }

  int _ms(int ms) => pyRound(ms * sampleRate / 1000);

  double _toTimestamp(int sample) {
    for (final i in _voice.reversed) {
      if (i.start <= sample && sample <= i.start + i.samples.length) {
        return i.timestamp + (sample - i.start) / sampleRate;
      }
    }
    final last = _voice.last;
    return last.timestamp + (sample - last.start) / sampleRate;
  }
}
