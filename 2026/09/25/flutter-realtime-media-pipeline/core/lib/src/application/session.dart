import 'dart:async';

import '../domain/action.dart';
import '../domain/media.dart';
import '../domain/support.dart';
import 'codec.dart';
import 'pipeline.dart';
import 'processor.dart';

/// What the pipeline runs against. Application code never asks which concrete
/// source or transport this is.
final class RealtimeSession {
  final MediaSource mediaSource;
  final ActionTransport actionTransport;

  const RealtimeSession({
    required this.mediaSource,
    required this.actionTransport,
  });
}

/// UI-independent session state (no ChangeNotifier, BuildContext, etc.).
sealed class SessionState {
  const SessionState();
}

final class SessionIdle extends SessionState {
  const SessionIdle();
}

final class SessionStarting extends SessionState {
  const SessionStarting();
}

final class SessionRunning extends SessionState {
  final SessionMetrics metrics;

  const SessionRunning(this.metrics);
}

final class SessionStopping extends SessionState {
  const SessionStopping();
}

final class SessionFailed extends SessionState {
  final String message;

  const SessionFailed(this.message);
}

final class SessionMetrics {
  final Duration elapsed;
  final String mediaKind;
  final String transportKind;
  final bool transportConnected;

  // Media
  final bool videoActive;
  final int? videoWidth;
  final int? videoHeight;
  final double? videoFps;
  final int? lastFrameSequence;
  final bool audioActive;
  final double? audioLevel;
  final MediaStats? stats;
  final bool audioEnabled;
  final bool videoEnabled;

  // Pipeline
  final double inputEventsPerSecond;
  final double processedEventsPerSecond;
  final int inputEvents;
  final int processedEvents;
  final int droppedVideoFrames;
  final int droppedAudioEvents;
  final Duration? lastLatency;
  final Duration? averageLatency;
  final Duration maxLatency;
  final String? lastResult;

  // Actions
  final int actionsSent;
  final int actionsReceived;
  final int sendErrors;
  final Duration? lastRoundTrip;
  final Map<String, Object?>? lastAction;
  final Map<String, int> resultCounts;
  final String? lastError;

  const SessionMetrics({
    required this.elapsed,
    required this.mediaKind,
    required this.transportKind,
    required this.transportConnected,
    required this.videoActive,
    required this.videoWidth,
    required this.videoHeight,
    required this.videoFps,
    required this.lastFrameSequence,
    required this.audioActive,
    required this.audioLevel,
    required this.stats,
    required this.audioEnabled,
    required this.videoEnabled,
    required this.inputEventsPerSecond,
    required this.processedEventsPerSecond,
    required this.inputEvents,
    required this.processedEvents,
    required this.droppedVideoFrames,
    required this.droppedAudioEvents,
    required this.lastLatency,
    required this.averageLatency,
    required this.maxLatency,
    required this.lastResult,
    required this.actionsSent,
    required this.actionsReceived,
    required this.sendErrors,
    required this.lastRoundTrip,
    required this.lastAction,
    required this.resultCounts,
    required this.lastError,
  });

  Map<String, Object?> toJson() {
    double? ms(Duration? d) => d == null ? null : d.inMicroseconds / 1000;
    return {
      'elapsedMs': ms(elapsed),
      'mediaKind': mediaKind,
      'transportKind': transportKind,
      'transportConnected': transportConnected,
      'videoActive': videoActive,
      'videoWidth': videoWidth,
      'videoHeight': videoHeight,
      'videoFps': videoFps,
      'lastFrameSequence': lastFrameSequence,
      'audioActive': audioActive,
      'audioLevel': audioLevel,
      'stats': stats?.toJson(),
      'inputEvents': inputEvents,
      'processedEvents': processedEvents,
      'inputEventsPerSecond': inputEventsPerSecond,
      'processedEventsPerSecond': processedEventsPerSecond,
      'droppedVideoFrames': droppedVideoFrames,
      'droppedAudioEvents': droppedAudioEvents,
      'lastLatencyMs': ms(lastLatency),
      'averageLatencyMs': ms(averageLatency),
      'maxLatencyMs': ms(maxLatency),
      'lastResult': lastResult,
      'resultCounts': resultCounts,
      'actionsSent': actionsSent,
      'actionsReceived': actionsReceived,
      'sendErrors': sendErrors,
      'lastRoundTripMs': ms(lastRoundTrip),
      'lastAction': lastAction,
      'lastError': lastError,
    };
  }
}

/// Owns one session's lifecycle: starts the source and pipeline, answers
/// pings, measures round trips, and publishes [SessionState] snapshots.
final class SessionController {
  final RealtimeSession session;
  final MediaSourceConfig config;
  final MonotonicClock clock;
  final AppLogger logger;
  final Duration tick;

  /// A track is reported inactive when nothing arrived for this long.
  final Duration activityTimeout;

  final StreamController<SessionState> _states = StreamController.broadcast();
  SessionState _state = const SessionIdle();
  SessionMetrics? _lastMetrics;
  final MediaProcessor _processor;
  final int _audioQueueCapacity;

  late final RealtimePipeline pipeline = RealtimePipeline(
    processor: _processor,
    clock: clock,
    logger: logger,
    audioQueueCapacity: _audioQueueCapacity,
  );

  StreamSubscription<PipelineOutput>? _outputSubscription;
  StreamSubscription<ActionEvent>? _transportSubscription;
  Future<void>? _pipelineDone;
  Timer? _timer;

  Duration _startedAt = Duration.zero;
  bool _transportConnected = false;
  bool _audioEnabled = true;
  bool _videoEnabled = true;
  Duration? _lastVideoAt;
  Duration? _lastAudioAt;
  VideoFrameInfo? _lastFrame;
  final List<VideoFrameInfo> _frameWindow = [];
  double? _audioLevel;
  MediaStats? _stats;
  String? _lastResult;
  final Map<String, int> _resultCounts = {};
  Action? _lastAction;
  String? _lastError;
  int _manualSent = 0;
  int _received = 0;
  int _pingCounter = 0;
  final Map<String, Duration> _pendingPings = {};
  Duration? _lastRoundTrip;
  int _lastInput = 0;
  int _lastProcessed = 0;
  Duration _lastTickAt = Duration.zero;
  double _inputRate = 0;
  double _processedRate = 0;

  SessionController({
    required this.session,
    required MediaProcessor processor,
    required this.config,
    MonotonicClock? clock,
    this.logger = const SilentLogger(),
    this.tick = const Duration(milliseconds: 250),
    this.activityTimeout = const Duration(seconds: 2),
    int audioQueueCapacity = 64,
  }) : clock = clock ?? StopwatchClock(),
       _processor = processor,
       _audioQueueCapacity = audioQueueCapacity;

  Stream<SessionState> get states => _states.stream;
  SessionState get state => _state;

  /// Metrics of the running session, or the final metrics after [stop].
  SessionMetrics? get lastMetrics => _lastMetrics;

  Future<void> start() async {
    if (_state is! SessionIdle && _state is! SessionFailed) {
      throw StateError('session already started');
    }
    _set(const SessionStarting());
    _startedAt = _lastTickAt = clock.now();
    _audioEnabled = config.audioEnabled;
    _videoEnabled = config.videoEnabled;

    // Subscribe before anything can emit: transport events first (connect is
    // called inside run), then the pipeline, then start the source.
    _transportSubscription = session.actionTransport.events.listen(
      _onTransportEvent,
    );
    _outputSubscription = pipeline.outputs.listen(_onOutput);
    _pipelineDone = pipeline.run(session).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      logger.error('pipeline failed', error, stackTrace);
      _lastError = '$error';
      _fail('pipeline failed: $error');
    });

    try {
      await session.mediaSource.start(config);
    } on MediaException catch (e) {
      _lastError = '${e.failure}';
      await _teardown();
      _fail('media source failed: ${e.failure}');
      return;
    }
    if (_state is SessionFailed) return;

    _timer = Timer.periodic(tick, (_) => _publish());
    _publish();
  }

  Future<void> stop() async {
    if (_state is SessionIdle || _state is SessionStopping) return;
    _set(const SessionStopping());
    _lastMetrics = _metrics();
    await _teardown();
    _lastMetrics = _metrics();
    _set(const SessionIdle());
  }

  Future<void> dispose() async {
    await stop();
    await pipeline.dispose();
    await _states.close();
  }

  Future<void> sendPing() async {
    final id = 'ping-${++_pingCounter}';
    _pendingPings[id] = clock.now();
    await _sendManual(PingAction(id));
  }

  Future<void> sendMove(double x, double y) =>
      _sendManual(MoveAction(x: x, y: y));

  Future<void> setTrackEnabled(MediaKind kind, bool enabled) async {
    await session.mediaSource.setTrackEnabled(kind, enabled);
    switch (kind) {
      case MediaKind.audio:
        _audioEnabled = enabled;
      case MediaKind.video:
        _videoEnabled = enabled;
    }
    _publish();
  }

  Future<void> _sendManual(Action action) async {
    try {
      await session.actionTransport.send(action);
      _manualSent++;
      _lastAction = action;
    } catch (e) {
      _lastError = 'send failed: $e';
      logger.warning(_lastError!);
    }
  }

  Future<void> _teardown() async {
    _timer?.cancel();
    _timer = null;
    try {
      await session.mediaSource.stop();
    } catch (e, st) {
      logger.error('media source stop failed', e, st);
    }
    pipeline.stop();
    await _pipelineDone;
    _pipelineDone = null;
    try {
      await session.actionTransport.disconnect();
    } catch (e, st) {
      logger.error('transport disconnect failed', e, st);
    }
    await _outputSubscription?.cancel();
    await _transportSubscription?.cancel();
    _outputSubscription = null;
    _transportSubscription = null;
  }

  void _onOutput(PipelineOutput output) {
    switch (output.event) {
      case VideoFrameObserved(:final frame):
        _lastVideoAt = clock.now();
        _lastFrame = frame;
        _frameWindow.add(frame);
        final cutoff = frame.timestamp - const Duration(milliseconds: 1500);
        _frameWindow.removeWhere((f) => f.timestamp < cutoff);
      case AudioLevelChanged(:final level):
        _lastAudioAt = clock.now();
        _audioLevel = level;
      case MediaStatsUpdated(:final stats):
        _stats = stats;
      case MediaErrorOccurred(:final failure):
        _lastError = '$failure';
      case MediaStarted() || MediaStopped():
        break;
    }
    for (final result in output.results) {
      _lastResult = result.label;
      _resultCounts.update(result.label, (n) => n + 1, ifAbsent: () => 1);
      if (result.action != null) _lastAction = result.action;
    }
  }

  void _onTransportEvent(ActionEvent event) {
    switch (event) {
      case TransportConnected():
        _transportConnected = true;
      case TransportDisconnected():
        _transportConnected = false;
      case TransportErrorOccurred(:final message):
        _lastError = 'transport: $message';
      case ActionReceived(:final action):
        _received++;
        switch (action) {
          case PingAction(:final id):
            // Answer directly: a pong is protocol, not a processing decision.
            unawaited(
              session.actionTransport.send(PongAction(id)).catchError((
                Object e,
              ) {
                _lastError = 'pong failed: $e';
              }),
            );
          case PongAction(:final id):
            final sentAt = _pendingPings.remove(id);
            if (sentAt != null) _lastRoundTrip = clock.now() - sentAt;
          case MoveAction() || CustomAction():
            break;
        }
    }
  }

  void _publish() {
    if (_state is SessionStopping || _state is SessionFailed) return;
    final metrics = _lastMetrics = _metrics();
    _set(SessionRunning(metrics));
  }

  SessionMetrics _metrics() {
    final now = clock.now();
    final c = pipeline.counters;
    final dt = (now - _lastTickAt).inMicroseconds / 1e6;
    if (dt >= 0.2) {
      _inputRate = (c.inputEvents - _lastInput) / dt;
      _processedRate = (c.processedEvents - _lastProcessed) / dt;
      _lastInput = c.inputEvents;
      _lastProcessed = c.processedEvents;
      _lastTickAt = now;
    }
    bool recent(Duration? at) => at != null && now - at < activityTimeout;
    final frame = _lastFrame;
    return SessionMetrics(
      elapsed: now - _startedAt,
      mediaKind: session.mediaSource.kind,
      transportKind: session.actionTransport.kind,
      transportConnected: _transportConnected,
      videoActive: recent(_lastVideoAt),
      videoWidth: frame?.width,
      videoHeight: frame?.height,
      videoFps: _fps(),
      lastFrameSequence: frame?.sequence,
      audioActive: recent(_lastAudioAt),
      audioLevel: _audioLevel,
      stats: _stats,
      audioEnabled: _audioEnabled,
      videoEnabled: _videoEnabled,
      inputEventsPerSecond: _inputRate,
      processedEventsPerSecond: _processedRate,
      inputEvents: c.inputEvents,
      processedEvents: c.processedEvents,
      droppedVideoFrames: c.droppedVideoFrames,
      droppedAudioEvents: c.droppedAudioEvents,
      lastLatency: c.lastLatency,
      averageLatency: c.processedEvents == 0
          ? null
          : c.totalLatency ~/ c.processedEvents,
      maxLatency: c.maxLatency,
      lastResult: _lastResult,
      actionsSent: c.actionsSent + _manualSent,
      actionsReceived: _received,
      sendErrors: c.sendErrors,
      lastRoundTrip: _lastRoundTrip,
      lastAction: switch (_lastAction) {
        null => null,
        final action => () {
          final (type, payload) = JsonActionCodec.typeAndPayload(action);
          return {'type': type, ...payload};
        }(),
      },
      resultCounts: Map.unmodifiable(_resultCounts),
      lastError: _lastError,
    );
  }

  /// Frame rate from sequence numbers over the last 1.5 s of source time.
  /// Works even when the source skips sequence numbers.
  double? _fps() {
    if (_frameWindow.length < 2) return null;
    final first = _frameWindow.first;
    final last = _frameWindow.last;
    final seconds = (last.timestamp - first.timestamp).inMicroseconds / 1e6;
    if (seconds <= 0) return null;
    return (last.sequence - first.sequence) / seconds;
  }

  void _fail(String message) {
    _timer?.cancel();
    _timer = null;
    _set(SessionFailed(message));
  }

  void _set(SessionState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }
}
