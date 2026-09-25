import 'dart:async';

import '../domain/action.dart';
import '../domain/media.dart';
import '../domain/support.dart';
import 'intake.dart';
import 'processor.dart';
import 'session.dart';

/// Counters the pipeline keeps while running. Rates are derived by readers.
final class PipelineCounters {
  int inputEvents = 0;
  int processedEvents = 0;
  int actionsSent = 0;
  int sendErrors = 0;
  int droppedVideoFrames = 0;
  int droppedAudioEvents = 0;
  Duration? lastLatency;
  Duration maxLatency = Duration.zero;
  Duration totalLatency = Duration.zero;
}

/// One processed event and what came out of it.
final class PipelineOutput {
  final MediaEvent event;
  final List<ProcessingResult> results;

  /// From entering the pipeline to the last action handed to the transport,
  /// including time spent waiting in the intake buffer.
  final Duration latency;

  const PipelineOutput(this.event, this.results, this.latency);
}

/// Media → Processing → Decision → Action → Transport, in Pure Dart.
///
/// The pipeline does not know where media comes from or where actions go:
/// that is decided entirely by the [RealtimeSession] passed to [run].
final class RealtimePipeline {
  final MediaProcessor processor;
  final MonotonicClock clock;
  final AppLogger logger;
  final int audioQueueCapacity;

  final PipelineCounters counters = PipelineCounters();
  final StreamController<PipelineOutput> _outputs = StreamController.broadcast(
    sync: true,
  );
  MediaEventIntake? _intake;

  RealtimePipeline({
    required this.processor,
    MonotonicClock? clock,
    this.logger = const SilentLogger(),
    this.audioQueueCapacity = 64,
  }) : clock = clock ?? StopwatchClock();

  Stream<PipelineOutput> get outputs => _outputs.stream;

  bool get isRunning => _intake != null;

  /// Runs until the media source's event stream ends or [stop] is called.
  ///
  /// Subscribes to media events synchronously, before any await, so a caller
  /// may start the media source right after calling [run] without losing the
  /// first events.
  Future<void> run(RealtimeSession session) async {
    if (_intake != null) throw StateError('pipeline is already running');
    final intake = _intake = MediaEventIntake(
      audioCapacity: audioQueueCapacity,
    );
    final subscription = session.mediaSource.events.listen(
      (event) {
        counters.inputEvents++;
        intake.add(QueuedMediaEvent(event, clock.now()));
      },
      onError: (Object error, StackTrace stackTrace) {
        logger.error('media source stream error', error, stackTrace);
      },
      onDone: intake.close,
    );

    try {
      await session.actionTransport.connect();
      while (true) {
        final queued = await intake.next();
        if (queued == null) break;
        await _process(queued, session.actionTransport);
        counters.droppedVideoFrames = intake.droppedVideoFrames;
        counters.droppedAudioEvents = intake.droppedAudioEvents;
      }
    } finally {
      counters.droppedVideoFrames = intake.droppedVideoFrames;
      counters.droppedAudioEvents = intake.droppedAudioEvents;
      await subscription.cancel();
      _intake = null;
    }
  }

  /// Makes [run] return after the event currently being processed.
  void stop() => _intake?.abort();

  Future<void> dispose() async {
    stop();
    await _outputs.close();
  }

  Future<void> _process(
    QueuedMediaEvent queued,
    ActionTransport transport,
  ) async {
    final List<ProcessingResult> results;
    try {
      results = await processor.process(queued.event);
    } catch (error, stackTrace) {
      logger.error('processor failed', error, stackTrace);
      counters.processedEvents++;
      return;
    }
    counters.processedEvents++;

    for (final result in results) {
      final action = result.action;
      if (action == null) continue;
      try {
        await transport.send(action);
        counters.actionsSent++;
      } catch (error, stackTrace) {
        counters.sendErrors++;
        logger.warning('send failed: $error');
        logger.debug('$stackTrace');
      }
    }

    final latency = clock.now() - queued.arrivedAt;
    counters.lastLatency = latency;
    counters.totalLatency += latency;
    if (latency > counters.maxLatency) counters.maxLatency = latency;
    if (!_outputs.isClosed) {
      _outputs.add(PipelineOutput(queued.event, results, latency));
    }
  }
}
