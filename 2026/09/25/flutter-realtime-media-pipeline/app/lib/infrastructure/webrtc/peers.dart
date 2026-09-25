import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_core/realtime_core.dart';

import 'rtc_support.dart';

/// Common signaling handling for both ends. The publisher offers, the viewer
/// answers; candidates that arrive before the remote description are queued.
abstract base class _Peer {
  final SignalingClient signaling;
  final AppLogger logger;
  final String role;

  RTCPeerConnection? pc;
  final ValueNotifier<RTCDataChannel?> channel = ValueNotifier(null);
  final ValueNotifier<RTCPeerConnectionState?> connectionState = ValueNotifier(
    null,
  );
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteSet = false;
  StreamSubscription<SignalingMessage>? _subscription;
  Future<void>? _opening;
  Future<void> _queue = Future.value();

  _Peer({required this.signaling, required this.role, required this.logger});

  /// Idempotent: the media source and the transport may both call it.
  Future<void> open() => _opening ??= _open();

  Future<void> _open() async {
    await signaling.connect();
    // Handle messages strictly in arrival order: an offer must be applied
    // before the candidates that follow it.
    _subscription = signaling.messages.listen((message) {
      _queue = _queue.then((_) => _handle(message)).catchError((
        Object e,
        StackTrace st,
      ) {
        logger.error('[$role] signaling handler failed', e, st);
      });
    });
    await signaling.send(PeerHello(role));
  }

  Future<void> _handle(SignalingMessage message);

  Future<RTCPeerConnection> _newPc() async {
    await _closePc();
    final pc = this.pc = await newPeerConnection();
    _remoteSet = false;
    pc.onIceCandidate = (candidate) {
      final c = candidate.candidate;
      if (c == null || c.isEmpty) return;
      unawaited(
        signaling.send(
          IceCandidateMessage(
            candidate: c,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
          ),
        ),
      );
    };
    pc.onConnectionState = (state) {
      logger.info('[$role] connection $state');
      connectionState.value = state;
    };
    return pc;
  }

  void _watchChannel(RTCDataChannel dc) {
    void update(RTCDataChannelState? state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        channel.value = dc;
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        if (identical(channel.value, dc)) channel.value = null;
      }
    }

    dc.onDataChannelState = update;
    update(dc.state);
  }

  Future<void> _setRemote(RTCSessionDescription description) async {
    await pc!.setRemoteDescription(description);
    _remoteSet = true;
    for (final c in _pendingCandidates) {
      await pc!.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  Future<void> _addCandidate(IceCandidateMessage m) async {
    final candidate = RTCIceCandidate(m.candidate, m.sdpMid, m.sdpMLineIndex);
    if (pc == null || !_remoteSet) {
      _pendingCandidates.add(candidate);
    } else {
      await pc!.addCandidate(candidate);
    }
  }

  Future<void> _closePc() async {
    final old = pc;
    pc = null;
    channel.value = null;
    _pendingCandidates.clear();
    if (old != null) await old.close();
  }

  Future<void> close() async {
    try {
      await signaling.send(const PeerBye());
    } catch (_) {}
    await _subscription?.cancel();
    await _closePc();
    await signaling.disconnect();
    _opening = null;
  }
}

/// Sends local camera/mic and owns the DataChannel. Re-offers whenever a
/// viewer says hello, so either side may start first.
final class PublisherPeer extends _Peer {
  final MediaStream stream;

  PublisherPeer({
    required super.signaling,
    required this.stream,
    super.logger = const SilentLogger(),
  }) : super(role: 'publisher');

  @override
  Future<void> _handle(SignalingMessage message) async {
    switch (message) {
      case PeerHello(role: 'viewer'):
        await _offer();
      case SdpAnswer(:final sdp):
        if (pc != null) await _setRemote(RTCSessionDescription(sdp, 'answer'));
      case IceCandidateMessage():
        await _addCandidate(message);
      case PeerBye():
        await _closePc();
      case PeerHello() || SdpOffer():
        break;
    }
  }

  Future<void> _offer() async {
    final pc = await _newPc();
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    final dc = await pc.createDataChannel(
      'actions',
      RTCDataChannelInit()..ordered = true,
    );
    _watchChannel(dc);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await signaling.send(SdpOffer(offer.sdp!));
  }
}

/// Receives remote media and the DataChannel.
final class ViewerPeer extends _Peer {
  final ValueNotifier<MediaStream?> remoteStream = ValueNotifier(null);

  ViewerPeer({required super.signaling, super.logger = const SilentLogger()})
    : super(role: 'viewer');

  @override
  Future<void> _handle(SignalingMessage message) async {
    switch (message) {
      case PeerHello(role: 'publisher'):
        // The publisher (re)joined after us: ask it for an offer.
        await signaling.send(PeerHello(role));
      case SdpOffer(:final sdp):
        await _answer(sdp);
      case IceCandidateMessage():
        await _addCandidate(message);
      case PeerBye():
        remoteStream.value = null;
        await _closePc();
      case PeerHello() || SdpAnswer():
        break;
    }
  }

  Future<void> _answer(String sdp) async {
    final pc = await _newPc();
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) remoteStream.value = event.streams.first;
    };
    pc.onDataChannel = _watchChannel;
    await _setRemote(RTCSessionDescription(sdp, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await signaling.send(SdpAnswer(answer.sdp!));
  }

  @override
  Future<void> close() async {
    remoteStream.value = null;
    await super.close();
  }
}
