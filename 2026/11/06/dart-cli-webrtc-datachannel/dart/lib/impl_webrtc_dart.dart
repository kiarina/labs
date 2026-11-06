/// [Rtc] on webrtc_dart 0.25.3 (pure Dart).
library;

import 'dart:async';

import 'package:webrtc_dart/webrtc_dart.dart';

import 'frames.dart' show fixReceived;
import 'rtc.dart';

class WebrtcDartRtc implements Rtc {
  WebrtcDartRtc({List<String> iceServers = const []}) : _iceServers = iceServers;

  final List<String> _iceServers;
  late final RTCPeerConnection _pc;
  final _signals = StreamController<Map<String, dynamic>>();
  final _states = StreamController<String>.broadcast();

  // Our candidates wait until our description went out; theirs until their
  // description is set (as the app does).
  var _described = false;
  final _outbox = <Map<String, dynamic>>[];
  var _remoteSet = false;
  final _early = <RTCIceCandidate>[];

  @override
  Stream<Map<String, dynamic>> get signals => _signals.stream;

  @override
  Stream<String> get states => _states.stream;

  @override
  Map<String, Object?> get info => {'impl': 'webrtc_dart', 'version': '0.25.3'};

  @override
  Future<TextChannel> start({required bool offer}) async {
    _pc = RTCPeerConnection(RtcConfiguration(
      iceServers: [for (final u in _iceServers) IceServer(urls: [u])],
    ));
    await _pc.waitForReady();
    _pc.onConnectionStateChange.listen((s) => _states.add(s.name));
    _pc.onIceCandidate.listen((c) {
      // webrtc_dart leaves sdpMid and sdpMLineIndex null; libwebrtc refuses a
      // candidate without either. The data-only offer has one m-line, mid 0.
      final m = {'k': 'cand', ...c.toJSON(), 'sdpMid': c.sdpMid ?? '0', 'sdpMLineIndex': c.sdpMLineIndex ?? 0};
      _described ? _signals.add(m) : _outbox.add(m);
    });
    final channel = Completer<dynamic>();
    if (offer) {
      channel.complete(_pc.createDataChannel('nerve', ordered: true));
      final o = await _pc.createOffer();
      await _pc.setLocalDescription(o);
      _describe({'k': 'offer', 'sdp': o.sdp});
    } else {
      _pc.onDataChannel.listen((dc) {
        if (!channel.isCompleted) channel.complete(dc);
      });
    }
    final dc = await channel.future;
    if (dc.state != DataChannelState.open) {
      await (dc.onStateChange as Stream).firstWhere((s) => s == DataChannelState.open);
    }
    return _Channel(dc);
  }

  void _describe(Map<String, dynamic> m) {
    _signals.add(m);
    _described = true;
    _outbox.forEach(_signals.add);
    _outbox.clear();
  }

  Future<void> _setRemote(String type, String sdp) async {
    await _pc.setRemoteDescription(RTCSessionDescription(type: type, sdp: sdp));
    _remoteSet = true;
    for (final c in _early) {
      await _pc.addIceCandidate(c);
    }
    _early.clear();
  }

  @override
  Future<void> onSignal(Map<String, dynamic> m) async {
    switch (m['k']) {
      case 'offer':
        await _setRemote('offer', m['sdp'] as String);
        final a = await _pc.createAnswer();
        await _pc.setLocalDescription(a);
        _describe({'k': 'answer', 'sdp': a.sdp});
      case 'answer':
        await _setRemote('answer', m['sdp'] as String);
      case 'cand':
        final s = m['candidate'] as String?;
        if (s == null || s.isEmpty) return;
        final c = RTCIceCandidate.fromSdp(s).copyWith(
          sdpMid: m['sdpMid'] as String?,
          sdpMLineIndex: (m['sdpMLineIndex'] as num?)?.toInt(),
        );
        _remoteSet ? await _pc.addIceCandidate(c) : _early.add(c);
    }
  }

  @override
  Future<void> close() async {
    await _pc.close();
  }
}

class _Channel implements TextChannel {
  _Channel(this._dc) {
    (_dc.onMessage as Stream).listen((m) {
      if (m is String) _messages.add(fixReceived(m));
    });
    (_dc.onStateChange as Stream).listen((s) {
      if (s == DataChannelState.closed && !_closed.isCompleted) _closed.complete();
    });
  }

  final dynamic _dc;
  final _messages = StreamController<String>();
  final _closed = Completer<void>();

  @override
  String get label => _dc.label as String;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get closed => _closed.future;

  /// Only ASCII survives webrtc_dart's sendString (see frames.dart).
  @override
  Future<void> send(String text) async {
    assert(text.codeUnits.every((u) => u < 0x80));
    await _dc.sendString(text);
  }
}
