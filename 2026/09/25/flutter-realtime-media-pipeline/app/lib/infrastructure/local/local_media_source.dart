import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_core/realtime_core.dart';

import '../webrtc/rtc_support.dart';

/// How [LocalMediaSource] observes its own tracks. flutter_webrtc has no
/// per-frame or audio-level callback for a local track, so the only portable
/// way to observe it is the stats of a sender carrying it.
enum LocalStatsProbe {
  /// No observation: only start/stop events.
  none,

  /// One PeerConnection with the tracks added and a local offer applied,
  /// never connected. Cheapest, if the platform reports stats in that state.
  sender,

  /// A connected in-process pair (sender → receiver). The receiver also
  /// decodes the video, which costs CPU.
  loopback,
}

/// Local camera and microphone via flutter_webrtc getUserMedia. Application
/// code only sees [MediaSource].
final class LocalMediaSource
    implements MediaSource, VideoPreviewSource, AdapterDiagnostics {
  final MonotonicClock clock;
  final Duration pollInterval;
  final LocalStatsProbe probe;

  final StreamController<MediaEvent> _events = StreamController.broadcast();
  final ValueNotifier<MediaStream?> _stream = ValueNotifier(null);
  final StatsEventConverter _converter = StatsEventConverter(
    side: StatsSide.outbound,
  );
  RTCPeerConnection? _sender;
  RTCPeerConnection? _receiver;
  Timer? _timer;
  bool _polling = false;
  bool _audioOn = true;
  bool _videoOn = true;
  int _polls = 0;
  Duration _statsTime = Duration.zero;
  Duration _maxStatsTime = Duration.zero;
  Duration? _captureLatency;

  LocalMediaSource({
    required this.clock,
    this.pollInterval = const Duration(milliseconds: 100),
    this.probe = LocalStatsProbe.loopback,
  });

  @override
  String get id => 'local';

  @override
  String get kind => 'local';

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  ValueListenable<MediaStream?> get previewStream => _stream;

  @override
  Future<List<MediaDevice>> availableDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      return [
        for (final d in devices)
          if (d.kind == 'audioinput' || d.kind == 'videoinput')
            MediaDevice(
              id: d.deviceId,
              label: d.label.isEmpty ? '(label hidden) ${d.deviceId}' : d.label,
              kind: d.kind == 'audioinput' ? MediaKind.audio : MediaKind.video,
            ),
      ];
    } catch (e) {
      throw MediaException(toMediaFailure(e));
    }
  }

  @override
  Future<void> start(MediaSourceConfig config) async {
    _audioOn = config.audioEnabled;
    _videoOn = config.videoEnabled;
    final began = clock.now();
    final stream = await captureUserMedia(config);
    _captureLatency = clock.now() - began;
    _stream.value = stream;
    try {
      await _startProbe(stream);
    } catch (e) {
      _events.add(
        MediaErrorOccurred(UnsupportedFeatureFailure('stats probe: $e')),
      );
    }
    _events.add(const MediaStarted());
    if (probe != LocalStatsProbe.none) {
      _timer = Timer.periodic(pollInterval, (_) => _poll());
    }
  }

  Future<void> _startProbe(MediaStream stream) async {
    if (probe == LocalStatsProbe.none) return;
    final sender = _sender = await newPeerConnection();
    for (final track in stream.getTracks()) {
      await sender.addTrack(track, stream);
    }
    if (probe == LocalStatsProbe.sender) {
      await sender.setLocalDescription(await sender.createOffer());
      return;
    }
    final receiver = _receiver = await newPeerConnection();
    sender.onIceCandidate = (c) => unawaited(receiver.addCandidate(c));
    receiver.onIceCandidate = (c) => unawaited(sender.addCandidate(c));
    final offer = await sender.createOffer();
    await sender.setLocalDescription(offer);
    await receiver.setRemoteDescription(offer);
    final answer = await receiver.createAnswer();
    await receiver.setLocalDescription(answer);
    await sender.setRemoteDescription(answer);
  }

  Future<void> _poll() async {
    final sender = _sender;
    if (_polling || sender == null || _events.isClosed) return;
    _polling = true;
    try {
      final started = clock.now();
      final reports = await sender.getStats();
      final took = clock.now() - started;
      _polls++;
      _statsTime += took;
      if (took > _maxStatsTime) _maxStatsTime = took;
      for (final e in _converter.convert(
        statsToMaps(reports),
        now: clock.now(),
        audioTrackEnabled: _audioOn,
        videoTrackEnabled: _videoOn,
      )) {
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
    final stream = _stream.value;
    final tracks = switch (kind) {
      MediaKind.audio => stream?.getAudioTracks(),
      MediaKind.video => stream?.getVideoTracks(),
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
    final stream = _stream.value;
    if (stream == null) return;
    _timer?.cancel();
    _timer = null;
    await _sender?.close();
    await _receiver?.close();
    _sender = null;
    _receiver = null;
    _stream.value = null;
    await stopStream(stream);
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
      'statsSide': 'outbound',
      'probe': probe.name,
      'captureMs': _captureLatency == null
          ? null
          : _captureLatency!.inMicroseconds / 1000,
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
