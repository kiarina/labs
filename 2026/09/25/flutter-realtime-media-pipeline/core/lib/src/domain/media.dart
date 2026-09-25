/// Media side of the domain: what a [MediaSource] reports, independent of
/// whether the media came from WebRTC, a local camera and microphone, or a mock.
library;

abstract interface class MediaSource {
  String get id;

  /// Human-readable kind, for display only (`local`, `webrtc`, `mock`).
  String get kind;

  Stream<MediaEvent> get events;

  Future<List<MediaDevice>> availableDevices();

  Future<void> start(MediaSourceConfig config);

  /// Mutes or unmutes a running track without stopping the source.
  Future<void> setTrackEnabled(MediaKind kind, bool enabled);

  Future<void> stop();

  Future<void> dispose();
}

enum MediaKind { audio, video }

final class MediaSourceConfig {
  final bool audioEnabled;
  final bool videoEnabled;

  final String? audioDeviceId;
  final String? videoDeviceId;

  const MediaSourceConfig({
    required this.audioEnabled,
    required this.videoEnabled,
    this.audioDeviceId,
    this.videoDeviceId,
  });
}

final class MediaDevice {
  final String id;
  final String label;
  final MediaKind kind;

  const MediaDevice({
    required this.id,
    required this.label,
    required this.kind,
  });

  @override
  String toString() => 'MediaDevice(${kind.name}, $id, $label)';
}

final class VideoFrameInfo {
  /// Monotonically increasing frame counter reported by the source. A source
  /// may skip numbers (it reports the latest frame it saw, not every frame).
  final int sequence;
  final int width;
  final int height;
  final Duration timestamp;

  const VideoFrameInfo({
    required this.sequence,
    required this.width,
    required this.height,
    required this.timestamp,
  });
}

/// Transport-level numbers a source may be able to report. Every field is
/// optional because what is observable differs per source and platform.
final class MediaStats {
  final Duration timestamp;
  final double? videoFps;
  final int? videoWidth;
  final int? videoHeight;
  final int? framesDecoded;
  final int? framesDropped;
  final double? audioLevel;
  final double? roundTripTime;
  final double? jitter;
  final int? packetsLost;
  final double? bitrateKbps;
  final bool? audioTrackEnabled;
  final bool? videoTrackEnabled;

  const MediaStats({
    required this.timestamp,
    this.videoFps,
    this.videoWidth,
    this.videoHeight,
    this.framesDecoded,
    this.framesDropped,
    this.audioLevel,
    this.roundTripTime,
    this.jitter,
    this.packetsLost,
    this.bitrateKbps,
    this.audioTrackEnabled,
    this.videoTrackEnabled,
  });

  Map<String, Object?> toJson() => {
    'videoFps': videoFps,
    'videoWidth': videoWidth,
    'videoHeight': videoHeight,
    'framesDecoded': framesDecoded,
    'framesDropped': framesDropped,
    'audioLevel': audioLevel,
    'roundTripTime': roundTripTime,
    'jitter': jitter,
    'packetsLost': packetsLost,
    'bitrateKbps': bitrateKbps,
    'audioTrackEnabled': audioTrackEnabled,
    'videoTrackEnabled': videoTrackEnabled,
  };
}

/// Events flowing from a platform adapter into Pure Dart.
///
/// All subclasses must live in this library: Dart only allows subclasses of a
/// `sealed` class in the same library, so they cannot be split into
/// `audio_event.dart` / `video_event.dart` as separate libraries.
sealed class MediaEvent {
  const MediaEvent();
}

final class MediaStarted extends MediaEvent {
  const MediaStarted();
}

final class MediaStopped extends MediaEvent {
  const MediaStopped();
}

final class AudioLevelChanged extends MediaEvent {
  /// 0.0 (silence) to 1.0 (full scale).
  final double level;
  final Duration timestamp;

  const AudioLevelChanged(this.level, {required this.timestamp});
}

final class VideoFrameObserved extends MediaEvent {
  final VideoFrameInfo frame;

  const VideoFrameObserved(this.frame);
}

final class MediaStatsUpdated extends MediaEvent {
  final MediaStats stats;

  const MediaStatsUpdated(this.stats);
}

final class MediaErrorOccurred extends MediaEvent {
  final MediaFailure failure;

  const MediaErrorOccurred(this.failure);
}

/// Platform exceptions are converted to these before reaching Application.
sealed class MediaFailure {
  final String message;

  const MediaFailure(this.message);

  String get code;

  @override
  String toString() => '$code: $message';
}

final class PermissionDeniedFailure extends MediaFailure {
  const PermissionDeniedFailure(super.message);

  @override
  String get code => 'permission_denied';
}

final class DeviceNotFoundFailure extends MediaFailure {
  const DeviceNotFoundFailure(super.message);

  @override
  String get code => 'device_not_found';
}

final class ConnectionFailure extends MediaFailure {
  const ConnectionFailure(super.message);

  @override
  String get code => 'connection';
}

final class UnsupportedFeatureFailure extends MediaFailure {
  const UnsupportedFeatureFailure(super.message);

  @override
  String get code => 'unsupported';
}

final class UnknownMediaFailure extends MediaFailure {
  const UnknownMediaFailure(super.message);

  @override
  String get code => 'unknown';
}

/// Thrown by adapters (e.g. from [MediaSource.start]) so that Application
/// never sees a platform exception type.
final class MediaException implements Exception {
  final MediaFailure failure;

  const MediaException(this.failure);

  @override
  String toString() => 'MediaException($failure)';
}
