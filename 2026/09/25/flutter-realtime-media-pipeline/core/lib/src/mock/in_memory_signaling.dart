import 'dart:async';

import '../domain/support.dart';

/// Two [SignalingClient]s wired to each other in memory, for a WebRTC
/// loopback inside one process. Messages go through JSON to catch anything
/// that would not survive a real signaling channel.
final class InMemorySignalingClient implements SignalingClient {
  final StreamController<SignalingMessage> _incoming =
      StreamController.broadcast();
  late final InMemorySignalingClient _peer;
  bool _connected = false;

  InMemorySignalingClient._();

  static (InMemorySignalingClient, InMemorySignalingClient) pair() {
    final a = InMemorySignalingClient._();
    final b = InMemorySignalingClient._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  Stream<SignalingMessage> get messages => _incoming.stream;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<void> send(SignalingMessage message) async {
    if (!_connected) throw StateError('signaling not connected');
    final copy = SignalingMessage.fromJson(message.toJson());
    // Deliver asynchronously, like a network would.
    scheduleMicrotask(() {
      if (!_peer._incoming.isClosed) _peer._incoming.add(copy);
    });
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _incoming.close();
  }
}
