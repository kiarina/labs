import 'dart:async';

import '../domain/action.dart';

/// Records sent actions. With [echoPings], replies to each [PingAction] with
/// a [PongAction] so round-trip measurement works without a peer.
final class MockActionTransport implements ActionTransport {
  final List<Action> sent = [];
  final bool echoPings;
  final Duration echoDelay;

  /// When set, [send] throws this instead of recording.
  Object? failWith;

  bool connected = false;
  final StreamController<ActionEvent> _events = StreamController.broadcast(
    sync: true,
  );

  MockActionTransport({this.echoPings = false, this.echoDelay = Duration.zero});

  @override
  String get kind => 'mock';

  @override
  Stream<ActionEvent> get events => _events.stream;

  /// Simulates an action arriving from the other side.
  void receive(Action action) => _events.add(ActionReceived(action));

  @override
  Future<void> connect() async {
    connected = true;
    _events.add(const TransportConnected());
  }

  @override
  Future<void> send(Action action) async {
    final failure = failWith;
    if (failure != null) throw failure;
    if (!connected) throw const ActionTransportException('not connected');
    sent.add(action);
    if (echoPings && action is PingAction) {
      Timer(echoDelay, () {
        if (!_events.isClosed) receive(PongAction(action.id));
      });
    }
  }

  @override
  Future<void> disconnect() async {
    if (!connected) return;
    connected = false;
    _events.add(const TransportDisconnected());
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }
}
