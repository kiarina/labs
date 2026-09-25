import 'dart:async';

import '../domain/action.dart';

/// Something that accepts an encoded action and may answer with one: an
/// in-process API, an HTTP endpoint, a robot SDK bridge.
abstract interface class OperationEndpoint {
  Future<String?> handle(String encodedAction);
}

/// [ActionTransport] for a local operation API. It encodes with the same
/// [ActionCodec] as the DataChannel transport, so the wire format is shared.
final class LocalOperationTransport implements ActionTransport {
  final OperationEndpoint endpoint;
  final ActionCodec codec;

  final StreamController<ActionEvent> _events = StreamController.broadcast();
  bool _connected = false;

  LocalOperationTransport({required this.endpoint, required this.codec});

  @override
  String get kind => 'local-api';

  @override
  Stream<ActionEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    _connected = true;
    _events.add(const TransportConnected());
  }

  @override
  Future<void> send(Action action) async {
    if (!_connected) throw const ActionTransportException('not connected');
    final reply = await endpoint.handle(codec.encode(action));
    if (reply != null && !_events.isClosed) {
      _events.add(ActionReceived(codec.decode(reply)));
    }
  }

  @override
  Future<void> disconnect() async {
    if (!_connected) return;
    _connected = false;
    _events.add(const TransportDisconnected());
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }
}

final class OperationApiState {
  final double x;
  final double y;
  final int handled;
  final Map<String, int> customCounts;
  final String? lastType;

  const OperationApiState({
    required this.x,
    required this.y,
    required this.handled,
    required this.customCounts,
    required this.lastType,
  });
}

/// Stand-in for a device operation API: keeps a cursor that [MoveAction]
/// moves (clamped to -1..1), counts custom actions, and answers pings.
final class SimulatedOperationApi implements OperationEndpoint {
  final ActionCodec codec;

  double _x = 0;
  double _y = 0;
  int _handled = 0;
  String? _lastType;
  final Map<String, int> _customCounts = {};
  final StreamController<OperationApiState> _changes =
      StreamController.broadcast();

  SimulatedOperationApi({required this.codec});

  Stream<OperationApiState> get changes => _changes.stream;

  OperationApiState get state => OperationApiState(
    x: _x,
    y: _y,
    handled: _handled,
    customCounts: Map.unmodifiable(_customCounts),
    lastType: _lastType,
  );

  @override
  Future<String?> handle(String encodedAction) async {
    final action = codec.decode(encodedAction);
    _handled++;
    String? reply;
    switch (action) {
      case PingAction(:final id):
        _lastType = 'ping';
        reply = codec.encode(PongAction(id));
      case PongAction():
        _lastType = 'pong';
      case MoveAction(:final x, :final y):
        _lastType = 'move';
        _x = (_x + x).clamp(-1.0, 1.0);
        _y = (_y + y).clamp(-1.0, 1.0);
      case CustomAction(:final type):
        _lastType = type;
        _customCounts.update(type, (n) => n + 1, ifAbsent: () => 1);
    }
    if (!_changes.isClosed) _changes.add(state);
    return reply;
  }

  Future<void> dispose() => _changes.close();
}
