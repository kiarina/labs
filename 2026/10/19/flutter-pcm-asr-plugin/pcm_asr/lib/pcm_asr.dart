/// Final transcription of finalized PCM segments with the OS speech engine.
///
/// The caller owns the microphone and decides where a segment starts and
/// ends. This package only turns one finished segment into final text and
/// hands the caller's [TranscribeRequest.id] back with it.
library;

import 'src/platform_interface.dart';
import 'src/types.dart';

export 'src/platform_interface.dart' show PcmAsrPlatform;
export 'src/types.dart';

class PcmAsr {
  const PcmAsr();

  /// What this device can do for [locale]. Read the fields, not just
  /// [RecognitionSupport.supported]: on-device processing and model download
  /// are reported separately.
  Future<RecognitionSupport> support({required String locale}) =>
      PcmAsrPlatform.instance.support(locale: locale);

  /// Gets the engine ready for [locale]. May download a model when
  /// [RecognitionSupport.modelState] is [ModelState.downloadable]; nothing is
  /// downloaded without this call.
  Future<void> prepare({required String locale}) =>
      PcmAsrPlatform.instance.prepare(locale: locale);

  /// Transcribes one finalized segment and returns its final text.
  Future<TranscribeResult> transcribe(TranscribeRequest request) =>
      PcmAsrPlatform.instance.transcribe(request);

  /// Stops the request with [id] if it is still running. Its future completes
  /// with [PcmAsrErrorCode.cancelled].
  Future<void> cancel(String id) => PcmAsrPlatform.instance.cancel(id);

  /// Cancels every running request and releases engine resources. The engine
  /// is re-created by the next call.
  Future<void> dispose() => PcmAsrPlatform.instance.dispose();
}
