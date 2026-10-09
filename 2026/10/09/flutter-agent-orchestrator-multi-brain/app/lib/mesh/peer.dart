import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../state/thread_view.dart' show Json;
import 'signal.dart';

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
  }

  @override
  final String name;
  final RTCPeerConnection pc;
  final RTCDataChannel channel;

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
  }
}

const _rtcConfig = {
  // Apps on one LAN (or Tailscale) reach each other by host candidates.
  'iceServers': <Object>[],
};

/// One peer connection being set up with another app. Handles its signaling
/// messages one at a time, in order, and holds ICE candidates until the
/// remote description is set: the offerer's candidates arrive before its
/// offer, and a candidate added before the remote description fails.
class _Negotiation {
  _Negotiation(this.pc);

  final RTCPeerConnection pc;
  bool _remoteSet = false;
  final _early = <RTCIceCandidate>[];

  /// Our own candidates wait until our offer or answer has gone out: the
  /// other app has no peer connection for us before it reads the offer.
  bool described = false;
  final outbox = <Json>[];

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

/// Keeps one data channel to every app this app needs: every pair of apps
/// where at least one is a brain (a brain serves every app's console and
/// uses the bodies it owns; two bodies have nothing to say to each other).
/// Of a pair, the app whose name sorts first makes the offer; offers,
/// answers and ICE candidates go through the signaling server.
class PeerManager {
  PeerManager(this.signal, {required this.onPeer, this.log}) {
    signal.addListener(_reconcile);
    signal.signals.listen(_onSignal);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _reconcile());
  }

  final SignalClient signal;
  final void Function(RtcPeer peer) onPeer;
  final void Function(String line)? log;
  final peers = <String, RtcPeer>{};
  final _negotiations = <String, _Negotiation>{};
  final _started = <String, DateTime>{};
  late final Timer _timer;

  bool _wanted(SignalNode n) =>
      n.online && n.name != signal.name && (signal.isBrain || n.brain);

  void _reconcile() {
    if (!signal.connected) return;
    final roster = {for (final n in signal.nodes) n.name: n};
    // Drop links to apps that left or no longer need one.
    for (final name in peers.keys.toList()) {
      final n = roster[name];
      if (n == null || !_wanted(n)) unawaited(peers.remove(name)!.close());
    }
    for (final n in roster.values) {
      if (!_wanted(n) || peers.containsKey(n.name)) continue;
      if (signal.name.compareTo(n.name) > 0) continue; // They offer.
      final since = _started[n.name];
      if (since != null &&
          DateTime.now().difference(since) < const Duration(seconds: 20)) {
        continue; // An offer is in flight.
      }
      unawaited(_offer(n.name));
    }
  }

  Future<_Negotiation> _fresh(String name) async {
    final old = _negotiations.remove(name);
    if (old != null) await old.pc.close();
    final pc = await createPeerConnection(_rtcConfig);
    final n = _Negotiation(pc);
    _negotiations[name] = n;
    pc.onIceCandidate = (c) {
      final m = {
        'k': 'ice',
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      };
      if (n.described) {
        signal.sendSignal(name, m);
      } else {
        n.outbox.add(m);
      }
    };
    return n;
  }

  void _described(String name, _Negotiation n, Json description) {
    signal.sendSignal(name, description);
    n.described = true;
    for (final m in n.outbox) {
      signal.sendSignal(name, m);
    }
    n.outbox.clear();
  }

  void _opened(String name, _Negotiation n, RTCDataChannel channel) {
    if (_negotiations[name] != n) return;
    _negotiations.remove(name);
    _started.remove(name);
    final peer = RtcPeer(name: name, pc: n.pc, channel: channel);
    peers[name] = peer;
    log?.call('linked $name');
    peer.closed.then((_) {
      if (peers[name] == peer) peers.remove(name);
      log?.call('unlinked $name');
    });
    onPeer(peer);
  }

  Future<void> _offer(String name) async {
    _started[name] = DateTime.now();
    log?.call('offer to $name');
    final n = await _fresh(name);
    final channel = await n.pc.createDataChannel(
      'orchestrator',
      RTCDataChannelInit()..ordered = true,
    );
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) _opened(name, n, channel);
    };
    final offer = await n.pc.createOffer();
    await n.pc.setLocalDescription(offer);
    _described(name, n, {'k': 'offer', 'sdp': offer.sdp});
  }

  // Signals from one app are handled one at a time, in order: the ICE
  // candidates behind an offer must wait until the offer has set up its
  // peer connection.
  final _chains = <String, Future<void>>{};

  void _onSignal((String, Json) s) {
    final (from, data) = s;
    _chains[from] = (_chains[from] ?? Future.value())
        .then((_) => _handleSignal(from, data))
        .catchError((Object e) => log?.call('signal from $from: $e'));
  }

  Future<void> _handleSignal(String from, Json data) async {
    if (data['k'] == 'offer') {
      // A new offer replaces whatever was set up with that app.
      log?.call('offer from $from');
      final old = peers.remove(from);
      if (old != null) await old.close();
      final n = await _fresh(from);
      n.pc.onDataChannel = (c) {
        void open() => _opened(from, n, c);
        c.onDataChannelState = (st) {
          if (st == RTCDataChannelState.RTCDataChannelOpen) open();
        };
        if (c.state == RTCDataChannelState.RTCDataChannelOpen) open();
      };
      await n.setRemote(RTCSessionDescription(data['sdp'] as String, 'offer'));
      final answer = await n.pc.createAnswer();
      await n.pc.setLocalDescription(answer);
      _described(from, n, {'k': 'answer', 'sdp': answer.sdp});
      return;
    }
    final n = _negotiations[from];
    if (n == null) return;
    switch (data['k']) {
      case 'answer':
        await n.setRemote(RTCSessionDescription(data['sdp'] as String, 'answer'));
      case 'ice':
        await n.addCandidate(data);
    }
  }

  void dispose() {
    _timer.cancel();
    signal.removeListener(_reconcile);
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
