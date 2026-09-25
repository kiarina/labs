import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_core/realtime_core.dart';

/// [ActionTransport] over an RTCDataChannel that a peer may replace on
/// renegotiation. Uses the shared [ActionCodec] wire format.
final class RtcDataChannelTransport implements ActionTransport {
  final ValueListenable<RTCDataChannel?> channel;
  final ActionCodec codec;
  final Future<void> Function()? onConnect;
  final Duration connectTimeout;
  final String label;

  final StreamController<ActionEvent> _events = StreamController.broadcast();
  RTCDataChannel? _bound;
  bool _active = false;

  RtcDataChannelTransport({
    required this.channel,
    required this.codec,
    this.onConnect,
    this.connectTimeout = const Duration(seconds: 30),
    this.label = 'datachannel',
  });

  @override
  String get kind => label;

  @override
  Stream<ActionEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    _active = true;
    channel.addListener(_rebind);
    await onConnect?.call();
    if (channel.value == null) {
      final opened = Completer<void>();
      void listener() {
        if (channel.value != null && !opened.isCompleted) opened.complete();
      }

      channel.addListener(listener);
      try {
        await opened.future.timeout(connectTimeout);
      } on TimeoutException {
        throw const ActionTransportException('DataChannel did not open');
      } finally {
        channel.removeListener(listener);
      }
    }
    _rebind();
  }

  void _rebind() {
    if (!_active) return;
    final dc = channel.value;
    if (identical(dc, _bound)) return;
    _bound?.onMessage = null;
    _bound = dc;
    if (dc == null) {
      _add(const TransportDisconnected());
      return;
    }
    dc.onMessage = (message) {
      if (message.isBinary) return;
      try {
        _add(ActionReceived(codec.decode(message.text)));
      } on FormatException catch (e) {
        _add(TransportErrorOccurred('bad action: ${e.message}'));
      }
    };
    _add(const TransportConnected());
  }

  @override
  Future<void> send(Action action) async {
    final dc = _bound;
    if (dc == null) throw const ActionTransportException('not connected');
    await dc.send(RTCDataChannelMessage(codec.encode(action)));
  }

  @override
  Future<void> disconnect() async {
    if (!_active) return;
    _active = false;
    channel.removeListener(_rebind);
    _bound?.onMessage = null;
    _bound = null;
    _add(const TransportDisconnected());
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }

  void _add(ActionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
