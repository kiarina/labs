import '../domain/action.dart';
import '../domain/media.dart';

final class ProcessingResult {
  /// Short name of the decision, for metrics and display.
  final String label;
  final Action? action;

  const ProcessingResult(this.label, {this.action});
}

/// The seam where processing can later move to an isolate or native code
/// (`InlineMediaProcessor` → `IsolateMediaProcessor`) without touching the
/// pipeline.
abstract interface class MediaProcessor {
  Future<List<ProcessingResult>> process(MediaEvent event);
}

/// Test processor that exercises the whole Media → Decision → Action path:
///
/// - `audio_peak` when the audio level rises above [audioPeakThreshold]
///   (rising edge only, so a loud room does not flood the transport)
/// - `video_tick` every time the frame sequence crosses a multiple of
///   [videoTickEvery]. Sources may skip sequence numbers, so this checks the
///   bucket rather than `sequence % n == 0`.
final class DebugMediaProcessor implements MediaProcessor {
  final double audioPeakThreshold;
  final int videoTickEvery;

  bool _aboveThreshold = false;
  int? _lastVideoBucket;

  DebugMediaProcessor({this.audioPeakThreshold = 0.7, this.videoTickEvery = 30})
    : assert(videoTickEvery > 0);

  @override
  Future<List<ProcessingResult>> process(MediaEvent event) async =>
      switch (event) {
        AudioLevelChanged(:final level) => _audio(level),
        VideoFrameObserved(:final frame) => _video(frame),
        MediaStarted() => const [ProcessingResult('media_started')],
        MediaStopped() => const [ProcessingResult('media_stopped')],
        MediaStatsUpdated() => const [],
        MediaErrorOccurred(:final failure) => [
          ProcessingResult('media_error:${failure.code}'),
        ],
      };

  List<ProcessingResult> _audio(double level) {
    final above = level > audioPeakThreshold;
    final rising = above && !_aboveThreshold;
    _aboveThreshold = above;
    if (!rising) return const [];
    return [
      ProcessingResult(
        'audio_peak',
        action: CustomAction(type: 'audio_peak', payload: {'level': level}),
      ),
    ];
  }

  List<ProcessingResult> _video(VideoFrameInfo frame) {
    final bucket = frame.sequence ~/ videoTickEvery;
    final last = _lastVideoBucket;
    _lastVideoBucket = bucket;
    if (last == null || bucket <= last) return const [];
    return [
      ProcessingResult(
        'video_tick',
        action: CustomAction(
          type: 'video_tick',
          payload: {'frame': frame.sequence},
        ),
      ),
    ];
  }
}
