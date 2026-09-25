import 'dart:async';
import 'dart:math' as math;

import '../domain/media.dart';
import '../domain/support.dart';

/// Hand-driven source for tests: nothing happens unless [emit] is called.
final class MockMediaSource implements MediaSource {
  final StreamController<MediaEvent> controller = StreamController.broadcast(
    sync: true,
  );

  @override
  final String id;

  bool started = false;
  MediaSourceConfig? lastConfig;
  final Map<MediaKind, bool> trackEnabled = {};

  MockMediaSource({this.id = 'mock'});

  @override
  String get kind => 'mock';

  @override
  Stream<MediaEvent> get events => controller.stream;

  void emit(MediaEvent event) => controller.add(event);

  @override
  Future<List<MediaDevice>> availableDevices() async => const [
    MediaDevice(
      id: 'mock-mic',
      label: 'Mock microphone',
      kind: MediaKind.audio,
    ),
    MediaDevice(id: 'mock-cam', label: 'Mock camera', kind: MediaKind.video),
  ];

  @override
  Future<void> start(MediaSourceConfig config) async {
    started = true;
    lastConfig = config;
    emit(const MediaStarted());
  }

  @override
  Future<void> setTrackEnabled(MediaKind kind, bool enabled) async {
    trackEnabled[kind] = enabled;
  }

  @override
  Future<void> stop() async {
    if (!started) return;
    started = false;
    emit(const MediaStopped());
  }

  /// Ends the event stream, which makes a running pipeline return.
  Future<void> close() => controller.close();

  @override
  Future<void> dispose() => close();
}

/// Timer-driven fake camera and microphone: 30 fps frames and a 50 Hz audio
/// level that swings above the peak threshold about once every 2 seconds.
/// Used by the "Mock Media → Mock API" mode and by load tests.
final class SyntheticMediaSource implements MediaSource {
  final MonotonicClock clock;
  final double fps;
  final double audioRate;
  final int width;
  final int height;

  final StreamController<MediaEvent> _events = StreamController.broadcast();
  final List<Timer> _timers = [];
  int _sequence = 0;
  bool _audioOn = true;
  bool _videoOn = true;

  SyntheticMediaSource({
    MonotonicClock? clock,
    this.fps = 30,
    this.audioRate = 50,
    this.width = 1280,
    this.height = 720,
  }) : clock = clock ?? StopwatchClock();

  @override
  String get id => 'synthetic';

  @override
  String get kind => 'mock';

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  Future<List<MediaDevice>> availableDevices() async => const [
    MediaDevice(
      id: 'synthetic-mic',
      label: 'Synthetic microphone',
      kind: MediaKind.audio,
    ),
    MediaDevice(
      id: 'synthetic-cam',
      label: 'Synthetic camera',
      kind: MediaKind.video,
    ),
  ];

  @override
  Future<void> start(MediaSourceConfig config) async {
    _audioOn = config.audioEnabled;
    _videoOn = config.videoEnabled;
    _events.add(const MediaStarted());
    _timers.add(
      Timer.periodic(_period(fps), (_) {
        if (!_videoOn) return;
        _events.add(
          VideoFrameObserved(
            VideoFrameInfo(
              sequence: ++_sequence,
              width: width,
              height: height,
              timestamp: clock.now(),
            ),
          ),
        );
      }),
    );
    _timers.add(
      Timer.periodic(_period(audioRate), (_) {
        if (!_audioOn) return;
        final t = clock.now().inMicroseconds / 1e6;
        final level = 0.45 + 0.4 * math.sin(2 * math.pi * t / 2.0);
        _events.add(AudioLevelChanged(level, timestamp: clock.now()));
      }),
    );
  }

  @override
  Future<void> setTrackEnabled(MediaKind kind, bool enabled) async {
    switch (kind) {
      case MediaKind.audio:
        _audioOn = enabled;
      case MediaKind.video:
        _videoOn = enabled;
    }
  }

  @override
  Future<void> stop() async {
    if (_timers.isEmpty) return;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _events.add(const MediaStopped());
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  static Duration _period(double hz) =>
      Duration(microseconds: (1e6 / hz).round());
}
