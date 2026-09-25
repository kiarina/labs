import 'dart:async';

import 'package:realtime_core/realtime_core.dart';
import 'package:test/test.dart';

VideoFrameObserved frame(int sequence, {int ms = 0}) => VideoFrameObserved(
  VideoFrameInfo(
    sequence: sequence,
    width: 1280,
    height: 720,
    timestamp: Duration(milliseconds: ms),
  ),
);

AudioLevelChanged audio(double level, {int ms = 0}) =>
    AudioLevelChanged(level, timestamp: Duration(milliseconds: ms));

/// Lets the pipeline drain everything emitted so far.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('golden path', () {
    test('mock video event → video_tick → MockActionTransport', () async {
      final media = MockMediaSource();
      final transport = MockActionTransport();
      final pipeline = RealtimePipeline(
        processor: DebugMediaProcessor(videoTickEvery: 30),
      );
      final session = RealtimeSession(
        mediaSource: media,
        actionTransport: transport,
      );

      final done = pipeline.run(session);
      await settle();
      media.emit(frame(29));
      await settle();
      media.emit(frame(30));
      await settle();
      media.emit(frame(31));
      await settle();
      await media.close();
      await done;

      expect(transport.sent, hasLength(1));
      final action = transport.sent.single as CustomAction;
      expect(action.type, 'video_tick');
      expect(action.payload, {'frame': 30});
      expect(pipeline.counters.inputEvents, 3);
      expect(pipeline.counters.processedEvents, 3);
    });

    test('mock audio event → audio_peak on the rising edge only', () async {
      final media = MockMediaSource();
      final transport = MockActionTransport();
      final pipeline = RealtimePipeline(processor: DebugMediaProcessor());
      final done = pipeline.run(
        RealtimeSession(mediaSource: media, actionTransport: transport),
      );
      await settle();
      for (final level in [0.2, 0.8, 0.9, 0.3, 0.75]) {
        media.emit(audio(level));
        await settle();
      }
      await media.close();
      await done;

      final levels = transport.sent
          .cast<CustomAction>()
          .map((a) => a.payload['level'])
          .toList();
      expect(levels, [0.8, 0.75]);
    });

    test('skipped sequence numbers still tick once per bucket', () async {
      final processor = DebugMediaProcessor(videoTickEvery: 10);
      final labels = <String>[];
      for (final seq in [3, 7, 25, 26, 31, 90]) {
        labels.addAll(
          (await processor.process(frame(seq))).map((r) => r.label),
        );
      }
      // 7 → 25 crosses one bucket boundary (or more); one tick per event.
      expect(labels, ['video_tick', 'video_tick', 'video_tick']);
    });
  });

  group('swapping source and transport leaves the pipeline unchanged', () {
    Future<List<Action>> runWith(
      MediaSource source,
      ActionTransport transport,
      List<Action> Function() sent,
    ) async {
      final pipeline = RealtimePipeline(
        processor: DebugMediaProcessor(videoTickEvery: 15),
      );
      final session = RealtimeSession(
        mediaSource: source,
        actionTransport: transport,
      );
      final done = pipeline.run(session);
      await source.start(
        const MediaSourceConfig(audioEnabled: true, videoEnabled: true),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      await source.stop();
      pipeline.stop();
      await done;
      return sent();
    }

    test('synthetic source → mock transport', () async {
      final transport = MockActionTransport();
      final sent = await runWith(
        SyntheticMediaSource(),
        transport,
        () => transport.sent,
      );
      final types = sent.cast<CustomAction>().map((a) => a.type).toSet();
      expect(types, containsAll(['video_tick', 'audio_peak']));
    });

    test('synthetic source → local operation API', () async {
      final api = SimulatedOperationApi(codec: JsonActionCodec());
      final transport = LocalOperationTransport(
        endpoint: api,
        codec: JsonActionCodec(),
      );
      await runWith(SyntheticMediaSource(), transport, () => const []);
      expect(api.state.customCounts['video_tick'], greaterThan(0));
      expect(api.state.customCounts['audio_peak'], greaterThan(0));
    });
  });

  group('backpressure', () {
    test('video is latest-frame-wins, audio is a bounded FIFO', () async {
      final media = MockMediaSource();
      final transport = MockActionTransport();
      final gate = Completer<void>();
      final seen = <MediaEvent>[];
      final processor = _RecordingProcessor(seen, gate.future);
      final pipeline = RealtimePipeline(
        processor: processor,
        audioQueueCapacity: 3,
      );
      final done = pipeline.run(
        RealtimeSession(mediaSource: media, actionTransport: transport),
      );
      await settle();

      // The first frame blocks the processor; everything after it queues.
      media.emit(frame(1));
      await settle();
      for (var i = 2; i <= 10; i++) {
        media.emit(frame(i));
      }
      for (var i = 1; i <= 5; i++) {
        media.emit(audio(i / 10));
      }
      gate.complete();
      await settle();
      await media.close();
      await done;

      final frames = seen.whereType<VideoFrameObserved>().map(
        (e) => e.frame.sequence,
      );
      final levels = seen.whereType<AudioLevelChanged>().map((e) => e.level);
      expect(frames, [1, 10]);
      expect(levels, [0.3, 0.4, 0.5]);
      expect(pipeline.counters.droppedVideoFrames, 8);
      expect(pipeline.counters.droppedAudioEvents, 2);
    });

    test('a slow processor keeps up with the newest frame', () async {
      final source = SyntheticMediaSource(fps: 60, audioRate: 1);
      final processor = _SlowProcessor(const Duration(milliseconds: 50));
      final pipeline = RealtimePipeline(processor: processor);
      final done = pipeline.run(
        RealtimeSession(
          mediaSource: source,
          actionTransport: MockActionTransport(),
        ),
      );
      await source.start(
        const MediaSourceConfig(audioEnabled: false, videoEnabled: true),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await source.stop();
      pipeline.stop();
      await done;

      final c = pipeline.counters;
      expect(c.droppedVideoFrames, greaterThan(c.inputEvents ~/ 2));
      // Nothing waits behind a backlog: latency stays near one processing
      // interval instead of growing with the run length.
      expect(c.maxLatency, lessThan(const Duration(milliseconds: 250)));
    });
  });

  group('errors', () {
    test('send failures are counted and do not stop the pipeline', () async {
      final media = MockMediaSource();
      final transport = MockActionTransport()..failWith = StateError('down');
      final pipeline = RealtimePipeline(
        processor: DebugMediaProcessor(videoTickEvery: 1),
      );
      final done = pipeline.run(
        RealtimeSession(mediaSource: media, actionTransport: transport),
      );
      await settle();
      media.emit(frame(1));
      await settle();
      media.emit(frame(2));
      await settle();
      transport.failWith = null;
      media.emit(frame(3));
      await settle();
      await media.close();
      await done;

      expect(pipeline.counters.sendErrors, 1);
      expect(transport.sent, hasLength(1));
    });
  });
}

final class _RecordingProcessor implements MediaProcessor {
  final List<MediaEvent> seen;
  final Future<void> gate;

  _RecordingProcessor(this.seen, this.gate);

  @override
  Future<List<ProcessingResult>> process(MediaEvent event) async {
    seen.add(event);
    await gate;
    return const [];
  }
}

final class _SlowProcessor implements MediaProcessor {
  final Duration delay;

  _SlowProcessor(this.delay);

  @override
  Future<List<ProcessingResult>> process(MediaEvent event) async {
    await Future<void>.delayed(delay);
    return const [];
  }
}
