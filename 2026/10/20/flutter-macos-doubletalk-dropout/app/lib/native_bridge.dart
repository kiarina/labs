import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc_external_media/flutter_webrtc_external_media.dart';

class CaptureBridge {
  ExternalMediaBridge? _bridge;
  Future<MediaStream> create() async {
    _bridge = await ExternalMediaBridge.create();
    return _bridge!.stream;
  }

  Stream<Map<dynamic, dynamic>> get renderReference => _bridge!.renderReference;
  Future<void> setSending(bool value) => _bridge!.setSending(value);
  Future<void> pushAudio(Uint8List bytes) async {
    await _bridge!.addAudio(bytes);
  }

  Future<void> pushVideo(
    Uint8List bytes,
    int width,
    int height,
    int timestamp,
  ) async {
    await _bridge!.addVideo(
      bytes,
      width: width,
      height: height,
      timestampUs: timestamp,
    );
  }

  Future<Map<String, Object?>> stats() async => _bridge?.stats() ?? {};
  Future<void> dispose() async {
    await _bridge?.dispose();
  }
}
