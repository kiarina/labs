import 'dart:typed_data';

/// A finalized chunk of audio the caller already owns.
///
/// Only 16-bit little-endian signed PCM is accepted. The caller keeps the
/// microphone, the voice activity detection and the speaker handling; this
/// package never records on its own.
class PcmSegment {
  PcmSegment({
    required this.pcm16le,
    required this.sampleRate,
    this.channels = 1,
  }) {
    if (pcm16le.isEmpty) throw ArgumentError('pcm16le is empty');
    if (pcm16le.length % (2 * channels) != 0) {
      throw ArgumentError('pcm16le must hold whole frames of $channels channel(s)');
    }
    if (sampleRate <= 0) throw ArgumentError('sampleRate must be positive');
    if (channels < 1) throw ArgumentError('channels must be at least 1');
  }

  /// Interleaved signed 16-bit little-endian samples.
  final Uint8List pcm16le;

  /// Samples per second per channel, e.g. 16000.
  final int sampleRate;

  /// Interleaved channel count. Mono is the recommended input.
  final int channels;

  int get frameCount => pcm16le.length ~/ (2 * channels);

  Duration get duration => Duration(microseconds: frameCount * 1000000 ~/ sampleRate);
}

/// One request: a segment, the language, and the caller's correlation ID.
class TranscribeRequest {
  const TranscribeRequest({
    required this.id,
    required this.audio,
    required this.locale,
    this.timeout = const Duration(seconds: 30),
  });

  /// Returned unchanged with the result so the caller can bind it to its own
  /// segment, speaker, or time range.
  final String id;

  final PcmSegment audio;

  /// BCP-47 tag such as `ja-JP`.
  final String locale;

  /// Upper bound for the whole request (model preparation excluded). When it
  /// passes, the native work is cancelled and [PcmAsrException] with
  /// [PcmAsrErrorCode.timeout] is thrown.
  final Duration timeout;
}

/// A time range inside the request's audio, in seconds from its start.
class TranscribedRange {
  const TranscribedRange({required this.text, required this.start, required this.end});

  final String text;
  final double start;
  final double end;

  Map<String, Object?> toJson() => {'text': text, 'start': start, 'end': end};
}

/// The final transcription of one request.
class TranscribeResult {
  const TranscribeResult({
    required this.id,
    required this.text,
    required this.engine,
    required this.locale,
    required this.elapsed,
    this.ranges = const [],
  });

  final String id;

  /// Final text. Empty when the engine finished without recognizing speech.
  final String text;

  /// Identifier of the engine that produced it, e.g. `apple.speech-analyzer`.
  final String engine;

  /// Locale the engine actually used (may be a close equivalent of the request).
  final String locale;

  /// From handing the audio to the engine to receiving the final result.
  final Duration elapsed;

  /// Final ranges as the engine reported them, in audio order. Empty when
  /// the engine gives no timing.
  final List<TranscribedRange> ranges;

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        'engine': engine,
        'locale': locale,
        'elapsed_ms': elapsed.inMilliseconds,
        'ranges': [for (final r in ranges) r.toJson()],
      };
}

/// Whether and how the engine's language model is present.
enum ModelState {
  /// Ready to use without any download.
  installed,

  /// Available, but [PcmAsr.prepare] must download or install it first.
  downloadable,

  /// Being downloaded or installed right now.
  installing,

  /// The engine cannot get a model for this locale on this device.
  unavailable,

  /// The engine does not expose model state (for example a cloud service).
  unknown,
}

/// What the engine on this device can do for one locale.
///
/// Every field is reported separately on purpose: a single boolean would hide
/// whether audio stays on the device or whether a download is needed.
class RecognitionSupport {
  const RecognitionSupport({
    required this.engine,
    required this.supported,
    required this.acceptsExternalPcm,
    required this.onDevice,
    required this.modelState,
    this.locale,
    this.sampleRates = const [],
    this.needsNetworkForModel = false,
    this.reason,
  });

  /// Engine identifier, or `none` when the platform has no engine.
  final String engine;

  /// True only when a [TranscribeRequest] for this locale can succeed on this
  /// device once [PcmAsr.prepare] has completed.
  final bool supported;

  /// True when the engine takes the caller's PCM without opening a microphone.
  final bool acceptsExternalPcm;

  /// True when audio and recognition stay on the device.
  final bool onDevice;

  final ModelState modelState;

  /// The locale the engine resolved the request to, or null when none.
  final String? locale;

  /// Sample rates the engine accepts directly. Others are resampled by the
  /// package when non-empty and the input differs.
  final List<int> sampleRates;

  /// True when preparing the model needs a network connection.
  final bool needsNetworkForModel;

  /// Why [supported] is false, in a stable machine-readable word.
  final String? reason;

  Map<String, Object?> toJson() => {
        'engine': engine,
        'supported': supported,
        'accepts_external_pcm': acceptsExternalPcm,
        'on_device': onDevice,
        'model_state': modelState.name,
        'locale': locale,
        'sample_rates': sampleRates,
        'needs_network_for_model': needsNetworkForModel,
        'reason': reason,
      };
}

enum PcmAsrErrorCode {
  /// The platform has no engine, or the OS is too old for it.
  unsupportedPlatform,

  /// The engine has no model for the requested locale.
  unsupportedLocale,

  /// The model is not installed and could not be installed.
  modelUnavailable,

  /// The PCM could not be used (bad length, rate, or channel count).
  invalidPcm,

  /// The request exceeded [TranscribeRequest.timeout].
  timeout,

  /// The request was cancelled by [PcmAsr.cancel] or [PcmAsr.dispose].
  cancelled,

  /// The engine failed for another reason; see the message.
  engineFailure,
}

class PcmAsrException implements Exception {
  const PcmAsrException(this.code, this.message, {this.details});

  final PcmAsrErrorCode code;
  final String message;
  final Object? details;

  @override
  String toString() => 'PcmAsrException(${code.name}): $message';
}
