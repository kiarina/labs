import 'dart:async';

import '../domain/action.dart';
import 'codec.dart';

/// The far end of an [ActionTransport] when it does no media processing
/// (the publishing peer, a robot stub): answers pings and counts what arrives.
final class ActionResponder {
  final ActionTransport transport;

  int received = 0;
  int pongsSent = 0;
  bool connected = false;
  Map<String, Object?>? lastAction;
  final Map<String, int> countsByType = {};
  String? lastError;

  final StreamController<void> _changes = StreamController.broadcast();
  StreamSubscription<ActionEvent>? _subscription;

  ActionResponder(this.transport);

  /// Fires after every change, for UIs that want to repaint.
  Stream<void> get changes => _changes.stream;

  void start() {
    _subscription ??= transport.events.listen(_onEvent);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _changes.close();
  }

  Map<String, Object?> toJson() => {
    'connected': connected,
    'received': received,
    'pongsSent': pongsSent,
    'countsByType': countsByType,
    'lastAction': lastAction,
    'lastError': lastError,
  };

  Future<void> _pong(String id) async {
    try {
      await transport.send(PongAction(id));
      pongsSent++;
    } catch (e) {
      lastError = 'pong failed: $e';
    }
  }

  void _onEvent(ActionEvent event) {
    switch (event) {
      case TransportConnected():
        connected = true;
      case TransportDisconnected():
        connected = false;
      case TransportErrorOccurred(:final message):
        lastError = message;
      case ActionReceived(:final action):
        received++;
        final (type, payload) = JsonActionCodec.typeAndPayload(action);
        final key = action is CustomAction ? action.type : type;
        countsByType.update(key, (n) => n + 1, ifAbsent: () => 1);
        lastAction = {'type': type, ...payload};
        if (action is PingAction) unawaited(_pong(action.id));
    }
    if (!_changes.isClosed) _changes.add(null);
  }
}
