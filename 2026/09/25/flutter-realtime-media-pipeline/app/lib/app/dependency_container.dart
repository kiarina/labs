import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_core/realtime_core.dart';

import '../infrastructure/local/local_media_source.dart';
import '../infrastructure/webrtc/peers.dart';
import '../infrastructure/webrtc/rtc_data_channel_transport.dart';
import '../infrastructure/webrtc/rtc_support.dart';
import '../infrastructure/webrtc/webrtc_media_source.dart';
import '../infrastructure/webrtc/websocket_signaling_client.dart';

enum SessionMode {
  mockToMock('mock', 'Mock Media → Mock API'),
  localToMock('local-mock', 'Local Camera + Mic → Mock API'),
  localToLocalApi('local-api', 'Local Camera + Mic → Local API'),
  webrtc('webrtc', 'WebRTC → DataChannel (viewer)'),
  loopback('loopback', 'WebRTC Loopback (Peer A ↔ Peer B)');

  final String key;
  final String label;

  const SessionMode(this.key, this.label);

  static SessionMode? byKey(String key) {
    for (final m in values) {
      if (m.key == key) return m;
    }
    return null;
  }
}

final class SessionOptions {
  final bool audioEnabled;
  final bool videoEnabled;
  final String? audioDeviceId;
  final String? videoDeviceId;
  final String signalingUrl;
  final String room;
  final LocalStatsProbe probe;

  const SessionOptions({
    this.audioEnabled = true,
    this.videoEnabled = true,
    this.audioDeviceId,
    this.videoDeviceId,
    this.signalingUrl = 'ws://127.0.0.1:8787',
    this.room = 'lab',
    this.probe = LocalStatsProbe.loopback,
  });

  MediaSourceConfig get mediaConfig => MediaSourceConfig(
    audioEnabled: audioEnabled,
    videoEnabled: videoEnabled,
    audioDeviceId: audioDeviceId,
    videoDeviceId: videoDeviceId,
  );

  Uri get signalingUri =>
      Uri.parse(signalingUrl).replace(queryParameters: {'room': room});
}

final class PrintLogger implements AppLogger {
  const PrintLogger();

  @override
  void debug(String message) {}

  @override
  void info(String message) => debugPrint('[info] $message');

  @override
  void warning(String message) => debugPrint('[warn] $message');

  @override
  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      debugPrint('[error] $message: $error');
}

/// Everything one running mode needs. Only [controller] (and through it the
/// [RealtimeSession]) matters to the pipeline; the rest serves the UI.
final class SessionBundle {
  final SessionMode mode;
  final SessionController controller;
  final VideoPreviewSource? preview;
  final SimulatedOperationApi? operationApi;

  /// Loopback only: Peer A, the far end of the DataChannel.
  final ActionResponder? remoteResponder;
  final ValueListenable<RTCPeerConnectionState?>? connectionState;
  final List<AdapterDiagnostics> _diagnostics;
  final List<Future<void> Function()> _cleanups;

  SessionBundle._({
    required this.mode,
    required this.controller,
    required List<AdapterDiagnostics> diagnostics,
    required List<Future<void> Function()> cleanups,
    this.preview,
    this.operationApi,
    this.remoteResponder,
    this.connectionState,
  }) : _diagnostics = diagnostics,
       _cleanups = cleanups;

  Map<String, Object?> diagnostics() => {
    for (final d in _diagnostics) ...d.diagnostics,
    if (remoteResponder != null) 'peerA': remoteResponder!.toJson(),
    if (operationApi != null)
      'operationApi': {
        'handled': operationApi!.state.handled,
        'customCounts': operationApi!.state.customCounts,
      },
  };

  Future<void> dispose() async {
    await controller.dispose();
    for (final cleanup in _cleanups.reversed) {
      try {
        await cleanup();
      } catch (e) {
        debugPrint('[warn] cleanup failed: $e');
      }
    }
  }
}

MediaProcessor defaultProcessor() =>
    DebugMediaProcessor(audioPeakThreshold: 0.7, videoTickEvery: 30);

/// Manual DI (spec §22): the only place that picks concrete adapters.
Future<SessionBundle> buildSession(
  SessionMode mode,
  SessionOptions options, {
  AppLogger logger = const PrintLogger(),
}) async {
  final clock = StopwatchClock();
  final codec = JsonActionCodec(idPrefix: 'b');
  final cleanups = <Future<void> Function()>[];

  SessionController controllerFor(RealtimeSession session) => SessionController(
    session: session,
    processor: defaultProcessor(),
    config: options.mediaConfig,
    clock: clock,
    logger: logger,
  );

  switch (mode) {
    case SessionMode.mockToMock:
      final source = SyntheticMediaSource(clock: clock);
      final transport = MockActionTransport(echoPings: true);
      cleanups.addAll([source.dispose, transport.dispose]);
      return SessionBundle._(
        mode: mode,
        controller: controllerFor(
          RealtimeSession(mediaSource: source, actionTransport: transport),
        ),
        diagnostics: const [],
        cleanups: cleanups,
      );

    case SessionMode.localToMock || SessionMode.localToLocalApi:
      final source = LocalMediaSource(clock: clock, probe: options.probe);
      cleanups.add(source.dispose);
      SimulatedOperationApi? api;
      final ActionTransport transport;
      if (mode == SessionMode.localToMock) {
        transport = MockActionTransport(echoPings: true);
      } else {
        api = SimulatedOperationApi(codec: JsonActionCodec(idPrefix: 'api'));
        transport = LocalOperationTransport(endpoint: api, codec: codec);
        cleanups.add(api.dispose);
      }
      cleanups.add(transport.dispose);
      return SessionBundle._(
        mode: mode,
        controller: controllerFor(
          RealtimeSession(mediaSource: source, actionTransport: transport),
        ),
        preview: source,
        operationApi: api,
        diagnostics: [source],
        cleanups: cleanups,
      );

    case SessionMode.webrtc:
      final viewer = ViewerPeer(
        signaling: WebSocketSignalingClient(options.signalingUri),
        logger: logger,
      );
      final source = WebRtcMediaSource(peer: viewer, clock: clock);
      final transport = RtcDataChannelTransport(
        channel: viewer.channel,
        codec: codec,
        onConnect: viewer.open,
      );
      cleanups.addAll([viewer.close, source.dispose, transport.dispose]);
      return SessionBundle._(
        mode: mode,
        controller: controllerFor(
          RealtimeSession(mediaSource: source, actionTransport: transport),
        ),
        preview: source,
        connectionState: viewer.connectionState,
        diagnostics: [source],
        cleanups: cleanups,
      );

    case SessionMode.loopback:
      final (signalingA, signalingB) = InMemorySignalingClient.pair();
      final localStream = await captureUserMedia(options.mediaConfig);
      cleanups.add(() => stopStream(localStream));
      final publisher = PublisherPeer(
        signaling: signalingA,
        stream: localStream,
        logger: logger,
      );
      final publisherTransport = RtcDataChannelTransport(
        channel: publisher.channel,
        codec: JsonActionCodec(idPrefix: 'a'),
        label: 'datachannel (peer A)',
      );
      final responder = ActionResponder(publisherTransport)..start();
      await publisher.open();
      unawaited(
        publisherTransport.connect().catchError((Object e) {
          logger.warning('peer A transport: $e');
        }),
      );
      cleanups.addAll([
        publisher.close,
        publisherTransport.dispose,
        responder.dispose,
      ]);

      final viewer = ViewerPeer(signaling: signalingB, logger: logger);
      final source = WebRtcMediaSource(peer: viewer, clock: clock);
      final transport = RtcDataChannelTransport(
        channel: viewer.channel,
        codec: codec,
        onConnect: viewer.open,
        label: 'datachannel (peer B)',
      );
      cleanups.addAll([viewer.close, source.dispose, transport.dispose]);
      return SessionBundle._(
        mode: mode,
        controller: controllerFor(
          RealtimeSession(mediaSource: source, actionTransport: transport),
        ),
        preview: source,
        remoteResponder: responder,
        connectionState: viewer.connectionState,
        diagnostics: [source],
        cleanups: cleanups,
      );
  }
}

/// The other device in two-device WebRTC mode: publishes camera and mic,
/// receives actions on the DataChannel and answers pings.
final class PublisherBundle {
  final MediaStream stream;
  final PublisherPeer peer;
  final RtcDataChannelTransport transport;
  final ActionResponder responder;

  PublisherBundle._(this.stream, this.peer, this.transport, this.responder);

  static Future<PublisherBundle> start(
    SessionOptions options, {
    AppLogger logger = const PrintLogger(),
  }) async {
    final stream = await captureUserMedia(options.mediaConfig);
    final peer = PublisherPeer(
      signaling: WebSocketSignalingClient(options.signalingUri),
      stream: stream,
      logger: logger,
    );
    final transport = RtcDataChannelTransport(
      channel: peer.channel,
      codec: JsonActionCodec(idPrefix: 'pub'),
      connectTimeout: const Duration(days: 1),
    );
    final responder = ActionResponder(transport)..start();
    try {
      await peer.open();
    } catch (e) {
      await stopStream(stream);
      throw MediaException(ConnectionFailure('signaling: $e'));
    }
    unawaited(transport.connect().catchError((Object _) {}));
    return PublisherBundle._(stream, peer, transport, responder);
  }

  Future<void> dispose() async {
    await responder.dispose();
    await transport.dispose();
    await peer.close();
    await stopStream(stream);
  }
}
