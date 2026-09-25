import 'dart:async';
import 'dart:convert';

import 'package:realtime_core/realtime_core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// [SignalingClient] for `core/bin/signaling_server.dart`.
final class WebSocketSignalingClient implements SignalingClient {
  final Uri uri;

  WebSocketChannel? _channel;
  final StreamController<SignalingMessage> _messages =
      StreamController.broadcast();

  WebSocketSignalingClient(this.uri);

  @override
  Stream<SignalingMessage> get messages => _messages.stream;

  @override
  Future<void> connect() async {
    final channel = _channel = WebSocketChannel.connect(uri);
    await channel.ready;
    channel.stream.listen(
      (data) {
        if (data is! String) return;
        try {
          final json = jsonDecode(data) as Map<String, Object?>;
          _messages.add(SignalingMessage.fromJson(json));
        } catch (_) {
          // Ignore messages this client does not understand.
        }
      },
      onDone: () {
        if (!_messages.isClosed) _messages.add(const PeerBye());
      },
    );
  }

  @override
  Future<void> send(SignalingMessage message) async {
    final channel = _channel;
    if (channel == null) throw StateError('signaling not connected');
    channel.sink.add(jsonEncode(message.toJson()));
  }

  @override
  Future<void> disconnect() async {
    await _channel?.sink.close();
    _channel = null;
    await _messages.close();
  }
}
