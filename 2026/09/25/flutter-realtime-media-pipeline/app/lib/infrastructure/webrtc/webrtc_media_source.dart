import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_core/realtime_core.dart';

import 'peers.dart';
import 'rtc_support.dart';

/// Remote media from a [ViewerPeer], observed by polling getStats().
final class WebRtcMediaSource
    implements MediaSource, VideoPreviewSource, AdapterDiagnostics {
  final ViewerPeer peer;
  final MonotonicClock clock;
  final Duration pollInterval;

  final StreamController<MediaEvent> _events = StreamController.broadcast();
  final StatsEventConverter _converter = StatsEventConverter(
    side: StatsSide.inbound,
  );
  Timer? _timer;
  bool _polling = false;
  bool _audioOn = true;
  bool _videoOn = true;
  int _polls = 0;
  Duration _statsTime = Duration.zero;
  Duration _maxStatsTime = Duration.zero;

  WebRtcMediaSource({
    required this.peer,
    required this.clock,
    this.pollInterval = const Duration(milliseconds: 100),
  });

  @override
  String get id => 'webrtc-remote';

  @override
  String get kind => 'webrtc';

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  ValueListenable<MediaStream?> get previewStream => peer.remoteStream;

  @override
  Future<List<MediaDevice>> availableDevices() async => const [];

  @override
  Future<void> start(MediaSourceConfig config) async {
    _audioOn = config.audioEnabled;
    _videoOn = config.videoEnabled;
    try {
      await peer.open();
    } catch (e) {
      throw MediaException(ConnectionFailure('$e'));
    }
    _events.add(const MediaStarted());
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    final pc = peer.pc;
    if (_polling || pc == null || _events.isClosed) return;
    _polling = true;
    try {
      final started = clock.now();
      final reports = await pc.getStats();
      final took = clock.now() - started;
      _polls++;
      _statsTime += took;
      if (took > _maxStatsTime) _maxStatsTime = took;
      final events = _converter.convert(
        statsToMaps(reports),
        now: clock.now(),
        audioTrackEnabled: _audioOn,
        videoTrackEnabled: _videoOn,
      );
      for (final e in events) {
        if (!_events.isClosed) _events.add(e);
      }
    } catch (e) {
      if (!_events.isClosed) {
        _events.add(MediaErrorOccurred(UnknownMediaFailure('getStats: $e')));
      }
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> setTrackEnabled(MediaKind kind, bool enabled) async {
    final tracks = switch (kind) {
      MediaKind.audio => peer.remoteStream.value?.getAudioTracks(),
      MediaKind.video => peer.remoteStream.value?.getVideoTracks(),
    };
    for (final t in tracks ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
    switch (kind) {
      case MediaKind.audio:
        _audioOn = enabled;
      case MediaKind.video:
        _videoOn = enabled;
    }
  }

  @override
  Future<void> stop() async {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    _events.add(const MediaStopped());
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  @override
  Map<String, Object?> get diagnostics {
    final s = _converter.lastSample;
    return {
      'statsSide': 'inbound',
      'polls': _polls,
      'averageGetStatsMs': _polls == 0
          ? null
          : _statsTime.inMicroseconds / _polls / 1000,
      'maxGetStatsMs': _maxStatsTime.inMicroseconds / 1000,
      'frameCounterSource': s?.frameCounterSource,
      'audioLevelSource': s?.audioLevelSource,
      'statsWidth': s?.width,
      'statsHeight': s?.height,
      'statsFps': s?.fps,
    };
  }
}
