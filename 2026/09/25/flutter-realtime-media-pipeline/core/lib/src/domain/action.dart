/// Action side of the domain: what the pipeline sends out, independent of
/// whether it goes over a WebRTC DataChannel, a local operation API, or a mock.
library;

/// Note: Flutter's widgets library also exports a class named `Action`.
/// Presentation code that imports both must hide one of them.
sealed class Action {
  const Action();
}

final class PingAction extends Action {
  final String id;

  const PingAction(this.id);
}

/// Reply to a [PingAction]; lets any transport measure a round trip.
final class PongAction extends Action {
  final String id;

  const PongAction(this.id);
}

final class MoveAction extends Action {
  final double x;
  final double y;

  const MoveAction({required this.x, required this.y});
}

final class CustomAction extends Action {
  final String type;
  final Map<String, Object?> payload;

  const CustomAction({required this.type, required this.payload});
}

sealed class ActionEvent {
  const ActionEvent();
}

final class TransportConnected extends ActionEvent {
  const TransportConnected();
}

final class TransportDisconnected extends ActionEvent {
  const TransportDisconnected();
}

final class ActionReceived extends ActionEvent {
  final Action action;

  const ActionReceived(this.action);
}

final class TransportErrorOccurred extends ActionEvent {
  final String message;

  const TransportErrorOccurred(this.message);
}

abstract interface class ActionTransport {
  /// Human-readable kind, for display only.
  String get kind;

  Stream<ActionEvent> get events;

  Future<void> connect();

  Future<void> send(Action action);

  Future<void> disconnect();

  Future<void> dispose();
}

final class ActionTransportException implements Exception {
  final String message;

  const ActionTransportException(this.message);

  @override
  String toString() => 'ActionTransportException($message)';
}

/// Wire format shared by every transport that crosses a process boundary.
abstract interface class ActionCodec {
  String encode(Action action);

  Action decode(String data);
}
