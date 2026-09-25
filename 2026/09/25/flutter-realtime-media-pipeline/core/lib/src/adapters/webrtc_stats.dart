import '../domain/media.dart';

/// Which side of a WebRTC connection the observed media is on.
enum StatsSide {
  /// Media received from the remote peer (`inbound-rtp`).
  inbound,

  /// Media captured locally and sent (`media-source`, then `outbound-rtp`).
  outbound,
}

/// One getStats() poll, reduced to what the pipeline needs.
final class WebRtcStatsSample {
  final int? frameCounter;
  final int? width;
  final int? height;
  final double? fps;
  final int? framesDropped;
  final double? audioLevel;
  final double? roundTripTime;
  final double? jitter;
  final int? packetsLost;
  final int? videoBytes;
  final int? audioBytes;

  /// Which stats field [frameCounter] came from, for the lab report.
  final String? frameCounterSource;
  final String? audioLevelSource;

  const WebRtcStatsSample({
    this.frameCounter,
    this.width,
    this.height,
    this.fps,
    this.framesDropped,
    this.audioLevel,
    this.roundTripTime,
    this.jitter,
    this.packetsLost,
    this.videoBytes,
    this.audioBytes,
    this.frameCounterSource,
    this.audioLevelSource,
  });
}

/// Parses W3C `RTCStatsReport` entries given as plain maps.
///
/// Platforms disagree on details (numbers sometimes arrive as strings, some
/// fields exist only on some platforms), so every read is defensive.
final class WebRtcStatsParser {
  const WebRtcStatsParser();

  WebRtcStatsSample parse(
    List<Map<String, Object?>> reports, {
    required StatsSide side,
  }) {
    Map<String, Object?>? byTypeKind(String type, String kind) {
      for (final r in reports) {
        if (r['type'] == type && (r['kind'] ?? r['mediaType']) == kind) {
          return r;
        }
      }
      return null;
    }

    final rtpType = side == StatsSide.inbound ? 'inbound-rtp' : 'outbound-rtp';
    final videoRtp = byTypeKind(rtpType, 'video');
    final audioRtp = byTypeKind(rtpType, 'audio');
    final videoSource = side == StatsSide.outbound
        ? byTypeKind('media-source', 'video')
        : null;
    final audioSource = side == StatsSide.outbound
        ? byTypeKind('media-source', 'audio')
        : null;

    // Frame counter: what best says "a new frame exists" on this side.
    final (frameCounter, frameCounterSource) = _firstInt([
      if (side == StatsSide.inbound) ...[
        (videoRtp, 'framesDecoded'),
        (videoRtp, 'framesReceived'),
      ] else ...[
        (videoSource, 'frames'),
        (videoRtp, 'framesEncoded'),
        (videoRtp, 'framesSent'),
      ],
    ]);

    final (audioLevel, audioLevelSource) = _firstDouble([
      (audioSource, 'audioLevel'),
      (audioRtp, 'audioLevel'),
    ]);

    return WebRtcStatsSample(
      frameCounter: frameCounter,
      frameCounterSource: frameCounterSource,
      width: _int(videoSource?['width']) ?? _int(videoRtp?['frameWidth']),
      height: _int(videoSource?['height']) ?? _int(videoRtp?['frameHeight']),
      fps:
          _double(videoSource?['framesPerSecond']) ??
          _double(videoRtp?['framesPerSecond']),
      framesDropped: _int(videoRtp?['framesDropped']),
      audioLevel: audioLevel,
      audioLevelSource: audioLevelSource,
      roundTripTime: _roundTripTime(reports),
      jitter: _double(videoRtp?['jitter']) ?? _double(audioRtp?['jitter']),
      packetsLost: _sumInt([
        videoRtp?['packetsLost'],
        audioRtp?['packetsLost'],
      ]),
      videoBytes: _int(
        videoRtp?[side == StatsSide.inbound ? 'bytesReceived' : 'bytesSent'],
      ),
      audioBytes: _int(
        audioRtp?[side == StatsSide.inbound ? 'bytesReceived' : 'bytesSent'],
      ),
    );
  }

  static double? _roundTripTime(List<Map<String, Object?>> reports) {
    for (final r in reports) {
      if (r['type'] != 'candidate-pair') continue;
      final selected =
          r['nominated'] == true ||
          r['nominated'] == 'true' ||
          r['selected'] == true ||
          r['selected'] == 'true';
      if (selected && r['state'] == 'succeeded') {
        final rtt = _double(r['currentRoundTripTime']);
        if (rtt != null) return rtt;
      }
    }
    return null;
  }

  static (int?, String?) _firstInt(List<(Map<String, Object?>?, String)> keys) {
    for (final (map, key) in keys) {
      final value = _int(map?[key]);
      if (value != null) return (value, key);
    }
    return (null, null);
  }

  static (double?, String?) _firstDouble(
    List<(Map<String, Object?>?, String)> keys,
  ) {
    for (final (map, key) in keys) {
      final value = _double(map?[key]);
      if (value != null) return (value, key);
    }
    return (null, null);
  }

  static int? _sumInt(List<Object?> values) {
    int? sum;
    for (final v in values) {
      final n = _int(v);
      if (n != null) sum = (sum ?? 0) + n;
    }
    return sum;
  }

  static int? _int(Object? v) => switch (v) {
    int() => v,
    double() => v.round(),
    String() => int.tryParse(v) ?? double.tryParse(v)?.round(),
    _ => null,
  };

  static double? _double(Object? v) => switch (v) {
    num() => v.toDouble(),
    String() => double.tryParse(v),
    _ => null,
  };
}

/// Turns successive stats samples into [MediaEvent]s.
///
/// Phase 1 has no per-frame callback from flutter_webrtc, so video frames are
/// observed by polling: when the frame counter advanced since the last poll, a
/// single [VideoFrameObserved] carries the newest counter value as its
/// sequence. The processor therefore sees 1 event per poll, not per frame.
final class StatsEventConverter {
  final WebRtcStatsParser parser;
  final StatsSide side;

  WebRtcStatsSample? _previous;
  Duration? _previousAt;
  int? _lastWidth;
  int? _lastHeight;

  StatsEventConverter({
    required this.side,
    this.parser = const WebRtcStatsParser(),
  });

  WebRtcStatsSample? get lastSample => _previous;

  List<MediaEvent> convert(
    List<Map<String, Object?>> reports, {
    required Duration now,
    required bool audioTrackEnabled,
    required bool videoTrackEnabled,
    int? fallbackWidth,
    int? fallbackHeight,
  }) {
    final sample = parser.parse(reports, side: side);
    final previous = _previous;
    final previousAt = _previousAt;
    _previous = sample;
    _previousAt = now;

    final width = sample.width ?? fallbackWidth ?? _lastWidth;
    final height = sample.height ?? fallbackHeight ?? _lastHeight;
    _lastWidth = width;
    _lastHeight = height;

    final events = <MediaEvent>[];
    final counter = sample.frameCounter;
    final advanced =
        counter != null &&
        (previous?.frameCounter == null || counter > previous!.frameCounter!);
    if (videoTrackEnabled && advanced) {
      events.add(
        VideoFrameObserved(
          VideoFrameInfo(
            sequence: counter,
            width: width ?? 0,
            height: height ?? 0,
            timestamp: now,
          ),
        ),
      );
    }
    final level = sample.audioLevel;
    if (audioTrackEnabled && level != null) {
      events.add(AudioLevelChanged(level, timestamp: now));
    }

    double? bitrate;
    if (previous != null && previousAt != null) {
      final seconds = (now - previousAt).inMicroseconds / 1e6;
      final bytes = (sample.videoBytes ?? 0) + (sample.audioBytes ?? 0);
      final prevBytes = (previous.videoBytes ?? 0) + (previous.audioBytes ?? 0);
      if (seconds > 0 && bytes >= prevBytes) {
        bitrate = (bytes - prevBytes) * 8 / 1000 / seconds;
      }
    }
    events.add(
      MediaStatsUpdated(
        MediaStats(
          timestamp: now,
          videoFps: sample.fps,
          videoWidth: width,
          videoHeight: height,
          framesDecoded: counter,
          framesDropped: sample.framesDropped,
          audioLevel: level,
          roundTripTime: sample.roundTripTime,
          jitter: sample.jitter,
          packetsLost: sample.packetsLost,
          bitrateKbps: bitrate,
          audioTrackEnabled: audioTrackEnabled,
          videoTrackEnabled: videoTrackEnabled,
        ),
      ),
    );
    return events;
  }
}
