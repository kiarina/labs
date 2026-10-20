import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Connects slot mode 3 (external) to the loopback MeanVC2 service.
/// Pulls received 48 kHz PCM from the native pipeline every 20 ms, sends it,
/// and pushes the converted 48 kHz PCM back for playout.
class VcClient {
  VcClient(this.channel);
  final MethodChannel channel;
  Socket? _socket;
  Timer? _timer;
  bool _busy = false;
  final _buffer = BytesBuilder(copy: false);
  Completer<Map<String, dynamic>>? _stats, _target;
  int sentSamples = 0, returnedSamples = 0;

  bool get connected => _socket != null;

  Future<void> start(int port) async {
    if (_socket != null) return;
    final socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(seconds: 5));
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    socket.listen(_onData, onDone: () => _socket = null, onError: (_) => _socket = null);
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => _pump());
  }

  void _frame(String kind, List<int> payload) {
    final head = ByteData(5)
      ..setUint8(0, kind.codeUnitAt(0))
      ..setUint32(1, payload.length, Endian.little);
    _socket?.add(head.buffer.asUint8List());
    if (payload.isNotEmpty) _socket?.add(payload);
  }

  Future<void> _pump() async {
    if (_busy || _socket == null) return;
    _busy = true;
    try {
      final bytes = await channel.invokeMethod<Uint8List>('pullExternal');
      if (bytes != null && bytes.isNotEmpty) {
        _frame('P', bytes);
        sentSamples += bytes.length ~/ 2;
      }
    } finally {
      _busy = false;
    }
  }

  void _onData(Uint8List data) {
    _buffer.add(data);
    var all = _buffer.takeBytes();
    var offset = 0;
    while (all.length - offset >= 5) {
      final view = ByteData.sublistView(all, offset);
      final n = view.getUint32(1, Endian.little);
      if (all.length - offset - 5 < n) break;
      final kind = String.fromCharCode(view.getUint8(0));
      final payload = Uint8List.sublistView(all, offset + 5, offset + 5 + n);
      offset += 5 + n;
      if (kind == 'P') {
        returnedSamples += n ~/ 2;
        channel.invokeMethod('pushExternal', {'bytes': Uint8List.fromList(payload)});
      } else if (kind == 'S') {
        _stats?.complete(jsonDecode(utf8.decode(payload)) as Map<String, dynamic>);
      } else if (kind == 'T') {
        _target?.complete(jsonDecode(utf8.decode(payload)) as Map<String, dynamic>);
      }
    }
    if (offset < all.length) _buffer.add(Uint8List.sublistView(all, offset));
  }

  Future<void> reset() async => _frame('R', const []);

  /// Replace the target voice: an audio file's bytes, or utf8 of 'asset:speaker1|2'.
  Future<Map<String, dynamic>> setTarget(List<int> payload) async {
    if (_socket == null) return {'ok': false, 'error': 'VC server not connected'};
    _target = Completer();
    _frame('T', payload);
    try {
      return await _target!.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      return {'ok': false, 'error': 'timeout'};
    }
  }

  Future<Map<String, dynamic>?> stats() async {
    if (_socket == null) return null;
    _stats = Completer();
    _frame('Q', const []);
    try {
      return await _stats!.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      return null;
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _socket?.close();
    _socket = null;
  }
}
