import 'dart:convert';

import '../domain/action.dart';

/// JSON envelope shared by the DataChannel and the local operation API:
///
/// ```json
/// {"version": 1, "id": "action-1", "type": "move",
///  "timestamp": 1750000000000, "payload": {"x": 0.4, "y": -0.2}}
/// ```
///
/// A [CustomAction] uses `"type": "custom"` and carries its own type in
/// `payload.name`, so custom names can never collide with built-in types.
final class JsonActionCodec implements ActionCodec {
  static const int version = 1;

  final int Function() _nowMillis;
  final String _idPrefix;
  int _next = 0;

  JsonActionCodec({int Function()? nowMillis, String idPrefix = 'action'})
    : _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
      _idPrefix = idPrefix;

  @override
  String encode(Action action) => jsonEncode(toEnvelope(action));

  Map<String, Object?> toEnvelope(Action action) {
    final (type, payload) = typeAndPayload(action);
    return {
      'version': version,
      'id': '$_idPrefix-${++_next}',
      'type': type,
      // Wall clock on purpose: the envelope crosses process boundaries, where
      // a monotonic clock of one side means nothing to the other.
      'timestamp': _nowMillis(),
      'payload': payload,
    };
  }

  /// The `type` and `payload` fields of the envelope for [action].
  static (String, Map<String, Object?>) typeAndPayload(Action action) =>
      switch (action) {
        PingAction(:final id) => ('ping', {'id': id}),
        PongAction(:final id) => ('pong', {'id': id}),
        MoveAction(:final x, :final y) => ('move', {'x': x, 'y': y}),
        CustomAction(:final type, :final payload) => (
          'custom',
          {'name': type, 'data': payload},
        ),
      };

  @override
  Action decode(String data) {
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException catch (e) {
      throw FormatException('action is not JSON: ${e.message}');
    }
    if (json is! Map<String, Object?>) {
      throw const FormatException('action must be a JSON object');
    }
    if (json['version'] != version) {
      throw FormatException('unsupported action version: ${json['version']}');
    }
    final payload = json['payload'];
    if (payload is! Map<String, Object?>) {
      throw const FormatException('action payload must be an object');
    }
    return switch (json['type']) {
      'ping' => PingAction(payload['id'] as String),
      'pong' => PongAction(payload['id'] as String),
      'move' => MoveAction(
        x: (payload['x'] as num).toDouble(),
        y: (payload['y'] as num).toDouble(),
      ),
      'custom' => CustomAction(
        type: payload['name'] as String,
        payload: Map<String, Object?>.from(payload['data'] as Map),
      ),
      final type => throw FormatException('unknown action type: $type'),
    };
  }
}
