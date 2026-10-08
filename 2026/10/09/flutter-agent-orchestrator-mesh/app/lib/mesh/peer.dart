import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../state/thread_view.dart' show Json;

/// A JSON message link to another app: a WebRTC data channel, or an
/// in-process loopback for the brain's own console.
abstract class Peer {
  /// The other app's name.
  String get name;

  Stream<Json> get messages;

  /// Completes when the link is gone.
  Future<void> get closed;

  void send(Json message);

  Future<void> close();
}

/// Messages larger than this are split (data channel messages over 256 KiB
/// are refused; strings count UTF-16 units, so stay well below).
const _chunkChars = 16000;

/// A peer over an ordered, reliable data channel. Messages are JSON text:
/// `J<json>` whole, or `C<id>:<index>/<count>:<part>` chunks.
class RtcPeer implements Peer {
  RtcPeer({
    required this.name,
    required this.pc,
    required this.channel,
    this.signaling,
  }) {
    channel.onMessage = _onMessage;
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelClosed) unawaited(close());
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(close());
      }
    };
    // The signaling socket closes at once when the other app quits; ICE
    // takes tens of seconds to notice.
    signaling?.done.then((_) => close());
  }

  @override
  final String name;
  final RTCPeerConnection pc;
  final RTCDataChannel channel;
  final WebSocket? signaling;

  /// On a body: the name the brain gave this app (it may differ from the
  /// one asked for).
  String? selfName;

  final _messages = StreamController<Json>.broadcast();
  final _closed = Completer<void>();
  final _parts = <String, List<String?>>{};
  int _seq = 0;

  /// Bytes and messages sent and received, for the README's numbers.
  int sentBytes = 0, receivedBytes = 0, sentMessages = 0, receivedMessages = 0;

  @override
  Stream<Json> get messages => _messages.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  void send(Json message) {
    if (_closed.isCompleted) return;
    final s = jsonEncode(message);
    sentMessages++;
    if (s.length <= _chunkChars) {
      _raw('J$s');
      return;
    }
    final id = '${++_seq}';
    final n = (s.length / _chunkChars).ceil();
    for (var i = 0; i < n; i++) {
      final part = s.substring(
        i * _chunkChars,
        min(s.length, (i + 1) * _chunkChars),
      );
      _raw('C$id:$i/$n:$part');
    }
  }

  void _raw(String text) {
    sentBytes += text.length;
    channel.send(RTCDataChannelMessage(text));
  }

  void _onMessage(RTCDataChannelMessage m) {
    final text = m.text;
    receivedBytes += text.length;
    if (text.startsWith('J')) {
      _deliver(text.substring(1));
      return;
    }
    if (!text.startsWith('C')) return;
    final head = text.indexOf(':');
    final head2 = text.indexOf(':', head + 1);
    final id = text.substring(1, head);
    final pos = text.substring(head + 1, head2).split('/');
    final index = int.parse(pos[0]), count = int.parse(pos[1]);
    final parts = _parts.putIfAbsent(
      id,
      () => List<String?>.filled(count, null),
    );
    parts[index] = text.substring(head2 + 1);
    if (parts.every((p) => p != null)) {
      _parts.remove(id);
      _deliver(parts.join());
    }
  }

  void _deliver(String json) {
    receivedMessages++;
    _messages.add((jsonDecode(json) as Map).cast<String, dynamic>());
  }

  @override
  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    await _messages.close();
    try {
      await channel.close();
      await pc.close();
    } catch (_) {
      // Already closing.
    }
    await signaling?.close();
  }
}

const _rtcConfig = {
  // Apps on one LAN (or Tailscale) reach each other by host candidates.
  'iceServers': <Object>[],
};

void _sendSignal(WebSocket ws, Json m) => ws.add(jsonEncode(m));

/// The socket's messages in order. One iterator reads them from the first
/// to the last: a broadcast stream drops what arrives while no one listens,
/// and the offer used to arrive while the body was still creating its peer
/// connection (the first attempt of every new app timed out).
StreamIterator<Json> _signals(WebSocket ws) => StreamIterator(
  ws.map((e) => (jsonDecode(e as String) as Map).cast<String, dynamic>()),
);

void _drain(StreamIterator<Json> it, void Function(Json m) onMessage) {
  unawaited(() async {
    while (await it.moveNext()) {
      onMessage(it.current);
    }
  }());
}

/// Handles signaling messages one at a time, in order, and holds ICE
/// candidates until the remote description is set: the brain's candidates
/// arrive before its offer, and a candidate added before the remote
/// description fails.
class _Negotiation {
  _Negotiation(this.pc);

  final RTCPeerConnection pc;
  Future<void> _last = Future.value();
  bool _remoteSet = false;
  final _early = <RTCIceCandidate>[];

  void run(Future<void> Function() step) {
    _last = _last.then((_) => step()).catchError((Object _) {});
  }

  Future<void> setRemote(RTCSessionDescription d) async {
    await pc.setRemoteDescription(d);
    _remoteSet = true;
    for (final c in _early) {
      await pc.addCandidate(c);
    }
    _early.clear();
  }

  Future<void> addCandidate(Json m) async {
    final c = RTCIceCandidate(
      m['candidate'] as String?,
      m['sdpMid'] as String?,
      (m['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (_remoteSet) {
      await pc.addCandidate(c);
    } else {
      _early.add(c);
    }
  }
}

/// The brain's side of signaling: a WebSocket server that bodies join.
/// Each join becomes a peer connection that the brain offers; once the data
/// channel opens, [onPeer] gets it. The socket stays open only to notice when
/// the body quits.
class SignalingServer {
  SignalingServer({
    required this.name,
    required this.port,
    required this.onPeer,
  });

  final String name;
  final int port;
  final void Function(RtcPeer peer) onPeer;

  /// Decides the joining app's name (null to refuse the name).
  String? Function(String requested)? claimName;
  HttpServer? _server;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response
          ..statusCode = HttpStatus.ok
          ..write('agent orchestrator brain $name\n');
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      unawaited(_accept(ws));
    });
  }

  Future<void> _accept(WebSocket ws) async {
    final signals = _signals(ws);
    if (!await signals.moveNext()) return;
    final join = signals.current;
    if (join['t'] != 'join') return ws.close();
    final requested = join['name'] as String;
    final given = claimName?.call(requested);
    if (given == null) {
      _sendSignal(ws, {'t': 'reject', 'reason': 'name "$requested" is taken'});
      return ws.close();
    }
    _sendSignal(ws, {'t': 'welcome', 'name': given, 'brain': name});

    final pc = await createPeerConnection(_rtcConfig);
    final channel = await pc.createDataChannel(
      'orchestrator',
      RTCDataChannelInit()..ordered = true,
    );
    pc.onIceCandidate = (c) => _sendSignal(ws, {
      't': 'ice',
      'candidate': c.candidate,
      'sdpMid': c.sdpMid,
      'sdpMLineIndex': c.sdpMLineIndex,
    });
    final negotiation = _Negotiation(pc);
    _drain(
      signals,
      (m) => negotiation.run(() async {
        switch (m['t']) {
          case 'answer':
            await negotiation.setRemote(
              RTCSessionDescription(m['sdp'] as String, 'answer'),
            );
          case 'ice':
            await negotiation.addCandidate(m);
        }
      }),
    );
    final opened = Completer<void>();
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen && !opened.isCompleted) {
        opened.complete();
      }
    };
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _sendSignal(ws, {'t': 'offer', 'sdp': offer.sdp});
    try {
      await opened.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      await pc.close();
      return ws.close();
    }
    onPeer(RtcPeer(name: given, pc: pc, channel: channel, signaling: ws));
  }

  Future<void> close() async => _server?.close(force: true);
}

/// A body's side: join the brain at [url] (ws://host:port) and answer its
/// offer. Returns the peer once the data channel is open.
Future<RtcPeer> joinBrain(
  String url,
  String name, {
  void Function(String step)? log,
}) async {
  final ws = await WebSocket.connect(url).timeout(const Duration(seconds: 5));
  log?.call('signaling open');
  final signals = _signals(ws);
  _sendSignal(ws, {'t': 'join', 'name': name});
  if (!await signals.moveNext()) throw StateError('brain closed the socket');
  final welcome = signals.current;
  if (welcome['t'] != 'welcome') {
    await ws.close();
    throw StateError('brain refused: ${welcome['reason']}');
  }
  log?.call('welcome as ${welcome['name']}');
  final pc = await createPeerConnection(_rtcConfig);
  log?.call('peer connection created');
  pc.onIceConnectionState = (s) => log?.call('ice ${s.name}');
  pc.onIceGatheringState = (s) => log?.call('gathering ${s.name}');
  final channel = Completer<RTCDataChannel>();
  final opened = Completer<void>();
  pc.onDataChannel = (c) {
    log?.call('data channel arrived (${c.state?.name})');
    c.onDataChannelState = (s) {
      log?.call('data channel ${s.name}');
      if (s == RTCDataChannelState.RTCDataChannelOpen && !opened.isCompleted) {
        opened.complete();
      }
    };
    // The channel may already be open when it arrives.
    if (c.state == RTCDataChannelState.RTCDataChannelOpen &&
        !opened.isCompleted) {
      opened.complete();
    }
    if (!channel.isCompleted) channel.complete(c);
  };
  pc.onIceCandidate = (c) => _sendSignal(ws, {
    't': 'ice',
    'candidate': c.candidate,
    'sdpMid': c.sdpMid,
    'sdpMLineIndex': c.sdpMLineIndex,
  });
  final negotiation = _Negotiation(pc);
  _drain(
    signals,
    (m) => negotiation.run(() async {
      switch (m['t']) {
        case 'offer':
          log?.call('offer');
          await negotiation.setRemote(
            RTCSessionDescription(m['sdp'] as String, 'offer'),
          );
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          _sendSignal(ws, {'t': 'answer', 'sdp': answer.sdp});
          log?.call('answer sent');
        case 'ice':
          log?.call(
            'remote candidate ${(m['candidate'] as String?)?.split(' ').skip(4).take(4).join(' ')}',
          );
          await negotiation.addCandidate(m);
      }
    }),
  );
  try {
    final c = await channel.future.timeout(const Duration(seconds: 20));
    await opened.future.timeout(const Duration(seconds: 20));
    return RtcPeer(
      name: welcome['brain'] as String,
      pc: pc,
      channel: c,
      signaling: ws,
    )..selfName = welcome['name'] as String;
  } on TimeoutException {
    await pc.close();
    await ws.close();
    rethrow;
  }
}

/// Two ends of an in-process link (the brain's own console). Messages go
/// through JSON so they look exactly like what remote consoles receive.
(Peer, Peer) loopbackPair(String a, String b) {
  final ab = StreamController<Json>.broadcast(sync: false);
  final ba = StreamController<Json>.broadcast(sync: false);
  final closed = Completer<void>();
  return (
    _Loopback(b, ba.stream, ab, closed),
    _Loopback(a, ab.stream, ba, closed),
  );
}

class _Loopback implements Peer {
  _Loopback(this.name, this.messages, this._out, this._closed);

  @override
  final String name;
  @override
  final Stream<Json> messages;
  final StreamController<Json> _out;
  final Completer<void> _closed;

  @override
  Future<void> get closed => _closed.future;

  @override
  void send(Json message) => _out.add(
    (jsonDecode(jsonEncode(message)) as Map).cast<String, dynamic>(),
  );

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// A short unique-enough name: the host name and four random hex digits.
String generateName() {
  final host = Platform.localHostname.split('.').first.toLowerCase();
  final r = Random().nextInt(0x10000).toRadixString(16).padLeft(4, '0');
  return '$host-$r';
}
