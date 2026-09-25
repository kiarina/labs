import 'package:realtime_core/realtime_core.dart';
import 'package:test/test.dart';

void main() {
  test('codec round-trips every action type', () {
    final codec = JsonActionCodec(nowMillis: () => 1750000000000);
    const actions = <Action>[
      PingAction('p1'),
      PongAction('p1'),
      MoveAction(x: 0.4, y: -0.2),
      CustomAction(type: 'video_tick', payload: {'frame': 1250}),
    ];
    for (final action in actions) {
      final decoded = codec.decode(codec.encode(action));
      final (decodedType, decodedPayload) = JsonActionCodec.typeAndPayload(
        decoded,
      );
      final (type, payload) = JsonActionCodec.typeAndPayload(action);
      expect(decodedType, type);
      expect(decodedPayload, payload);
    }
    expect(codec.toEnvelope(const MoveAction(x: 0.4, y: -0.2)), {
      'version': 1,
      'id': 'action-5',
      'type': 'move',
      'timestamp': 1750000000000,
      'payload': {'x': 0.4, 'y': -0.2},
    });
    expect(() => codec.decode('{"version":2}'), throwsFormatException);
    expect(() => codec.decode('nope'), throwsFormatException);
  });

  test('signaling messages survive JSON', () {
    const messages = <SignalingMessage>[
      SdpOffer('v=0'),
      SdpAnswer('v=0'),
      IceCandidateMessage(candidate: 'c', sdpMid: '0', sdpMLineIndex: 0),
      PeerHello('viewer'),
      PeerBye(),
    ];
    for (final m in messages) {
      expect(SignalingMessage.fromJson(m.toJson()).toJson(), m.toJson());
    }
  });

  test('session controller runs, answers pings and measures RTT', () async {
    final source = SyntheticMediaSource();
    final transport = MockActionTransport(
      echoPings: true,
      echoDelay: const Duration(milliseconds: 20),
    );
    final controller = SessionController(
      session: RealtimeSession(mediaSource: source, actionTransport: transport),
      processor: DebugMediaProcessor(),
      config: const MediaSourceConfig(audioEnabled: true, videoEnabled: true),
      tick: const Duration(milliseconds: 100),
    );
    final states = <SessionState>[];
    controller.states.listen(states.add);

    await controller.start();
    await controller.sendPing();
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    // Receiving a ping from the other side is answered with a pong.
    transport.receive(const PingAction('remote-1'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.state, isA<SessionRunning>());
    await controller.stop();
    await Future<void>.delayed(Duration.zero); // deliver queued states

    final m = controller.lastMetrics!;
    // Final metrics are taken after teardown, so the transport has already
    // disconnected; activity flags still reflect the last 2 s.
    expect(m.videoActive, isTrue);
    expect(m.videoWidth, 1280);
    expect(m.videoFps, closeTo(30, 5));
    expect(m.audioActive, isTrue);
    expect(
      m.lastRoundTrip,
      greaterThanOrEqualTo(const Duration(milliseconds: 20)),
    );
    expect(m.actionsReceived, 2); // our pong + their ping
    expect(transport.sent.whereType<PongAction>().single.id, 'remote-1');
    expect(m.resultCounts['video_tick'], greaterThan(0));

    expect(states.first, isA<SessionStarting>());
    expect(states.last, isA<SessionIdle>());
    expect(transport.connected, isFalse);
  });

  test(
    'a media failure becomes SessionFailed, not a platform exception',
    () async {
      final controller = SessionController(
        session: RealtimeSession(
          mediaSource: _DeniedSource(),
          actionTransport: MockActionTransport(),
        ),
        processor: DebugMediaProcessor(),
        config: const MediaSourceConfig(audioEnabled: true, videoEnabled: true),
      );
      await controller.start();
      final state = controller.state;
      expect(state, isA<SessionFailed>());
      expect((state as SessionFailed).message, contains('permission_denied'));
    },
  );
}

final class _DeniedSource implements MediaSource {
  final MockMediaSource _inner = MockMediaSource();

  @override
  String get id => 'denied';

  @override
  String get kind => 'mock';

  @override
  Stream<MediaEvent> get events => _inner.events;

  @override
  Future<List<MediaDevice>> availableDevices() async => const [];

  @override
  Future<void> start(MediaSourceConfig config) async =>
      throw const MediaException(PermissionDeniedFailure('camera'));

  @override
  Future<void> setTrackEnabled(MediaKind kind, bool enabled) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _inner.dispose();
}
