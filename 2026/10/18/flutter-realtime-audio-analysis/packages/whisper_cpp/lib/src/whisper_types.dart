// Platform-independent value types shared by the native (dart:ffi) and web
// backends. Must not import dart:ffi or dart:io.

/// One decoded segment. [start] / [end] are seconds from the start of the
/// PCM passed to `transcribe`.
class WhisperSegment {
  final double start;
  final double end;
  final String text;

  const WhisperSegment({
    required this.start,
    required this.end,
    required this.text,
  });

  Map<String, Object?> toJson() => {'start': start, 'end': end, 'text': text};

  @override
  String toString() =>
      '[${start.toStringAsFixed(2)} - ${end.toStringAsFixed(2)}] $text';
}

/// Result of one `transcribe` call.
class WhisperResult {
  /// Concatenated text of all segments (trimmed).
  final String text;
  final List<WhisperSegment> segments;

  /// Language code used or detected by whisper (e.g. `ja`).
  final String language;

  /// Wall-clock time spent inside whisper (encode + decode) for this call.
  final Duration elapsed;

  const WhisperResult({
    required this.text,
    required this.segments,
    required this.language,
    required this.elapsed,
  });

  Map<String, Object?> toJson() => {
    'text': text,
    'segments': [for (final s in segments) s.toJson()],
    'language': language,
    'elapsedMs': elapsed.inMicroseconds / 1000.0,
  };

  @override
  String toString() => 'WhisperResult($language, ${elapsed.inMilliseconds} ms, "$text")';
}

/// Decoding options for `transcribe`. Greedy sampling is always used.
class WhisperOptions {
  /// ISO 639-1 code (`ja`, `en`, ...) or `auto` for detection.
  final String language;

  /// Number of CPU threads; 0 lets whisper.cpp choose (min(4, cores)).
  final int threads;

  /// Translate to English instead of transcribing.
  final bool translate;

  /// Do not feed previous text as a prompt (each utterance is independent).
  final bool noContext;

  /// Suppress non-speech tokens (whisper.cpp `suppress_nst`).
  final bool suppressNonSpeech;

  /// Initial sampling temperature. whisper.cpp still applies its default
  /// temperature fallback (+0.2) when decoding fails its quality checks.
  final double temperature;

  /// Shrink the encoder to the audio's length instead of whisper's fixed
  /// 30 s window (whisper.cpp `audio_ctx`). Much faster for short
  /// utterances; whisper was trained on 30 s windows, so accuracy may drop.
  final bool fitAudioCtx;

  /// Lower bound of the shrunk context, in encoder frames (1500 = 30 s).
  final int minAudioCtx;

  const WhisperOptions({
    this.language = 'ja',
    this.threads = 0,
    this.translate = false,
    this.noContext = true,
    this.suppressNonSpeech = true,
    this.temperature = 0,
    this.fitAudioCtx = false,
    this.minAudioCtx = 256,
  });

  /// whisper.cpp audio_ctx for [samples] of 16 kHz audio (0 = full 1500).
  int audioCtxFor(int samples) {
    if (!fitAudioCtx) return 0;
    // 1500 frames per 30 s; a little margin, rounded up to 64 for the kernels
    final frames = (samples / 16000 * 50 * 1.1).ceil() + 32;
    final ctx = ((frames + 63) ~/ 64) * 64;
    return ctx.clamp(minAudioCtx, 1500);
  }

  Map<String, Object?> toJson() => {
    'language': language,
    'threads': threads,
    'translate': translate,
    'noContext': noContext,
    'suppressNonSpeech': suppressNonSpeech,
    'temperature': temperature,
    'fitAudioCtx': fitAudioCtx,
    'minAudioCtx': minAudioCtx,
  };
}

/// Thrown when loading a model or transcribing fails.
class WhisperException implements Exception {
  final String message;
  const WhisperException(this.message);
  @override
  String toString() => 'WhisperException: $message';
}
