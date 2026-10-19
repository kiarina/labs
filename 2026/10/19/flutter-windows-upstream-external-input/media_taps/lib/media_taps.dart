/// Taps decoded video frames and audio PCM from flutter_webrtc tracks.
///
/// Native platforms attach a sink to the native track that flutter_webrtc
/// owns (looked up by track id); the web attaches to the underlying JS track.
/// Dart pulls what arrived with [MediaTaps.poll].
library;

import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'src/backend_io.dart'
    if (dart.library.js_interop) 'src/backend_web.dart';

enum TapKind { video, audio }

final class TapOptions {
  /// Video: width to scale to before converting to I420 (0 = do not convert,
  /// -1 = convert at full resolution). Audio: ignored.
  final int convertWidth;

  /// Hand the converted luma plane / PCM over to Dart via [MediaTaps.poll].
  final bool deliver;

  const TapOptions({this.convertWidth = 0, this.deliver = false});

  Map<String, Object?> toMap() => {
    'convertWidth': convertWidth,
    'deliver': deliver,
  };
}

final class VideoPayload {
  final int width;
  final int height;

  /// Luma (Y) plane, tightly packed (stride == width).
  final Uint8List luma;

  const VideoPayload(this.width, this.height, this.luma);
}

/// What one tap produced since the previous poll.
final class TapSnapshot {
  final int id;
  final TapKind kind;

  /// Cumulative counters and latest facts reported by the platform:
  /// `callbacks`, `width`, `height`, `rotation`, `bufferType`, `convertCount`,
  /// `convertUsTotal`, `convertUsMax`, `droppedToDart`, `sampleRate`,
  /// `channels`, `framesPerChunk`, `bitsPerSample`, `rms` (since last poll).
  final Map<String, Object?> counters;
  final List<VideoPayload> frames;

  /// 16-bit PCM delivered since the previous poll (interleaved).
  final Int16List? pcm;

  const TapSnapshot({
    required this.id,
    required this.kind,
    required this.counters,
    this.frames = const [],
    this.pcm,
  });
}

abstract interface class MediaTapsBackend {
  String get platform;

  Future<int> attach(
    MediaStreamTrack track, {
    required bool local,
    MediaStream? stream,
    TapOptions options = const TapOptions(),
  });

  Future<void> detach(int id);

  Future<List<TapSnapshot>> poll();
}

abstract final class MediaTaps {
  static final MediaTapsBackend instance = createBackend();
}
