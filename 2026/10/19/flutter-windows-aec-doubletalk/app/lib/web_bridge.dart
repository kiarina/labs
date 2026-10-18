import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;

@JS('createExternalCaptureBridge')
external JSPromise<_Bridge> _createBridge();

extension type _Bridge(JSObject _) implements JSObject {
  external web.MediaStream get stream;
  external void pushAudio(JSUint8Array bytes);
  external void pushVideo(JSUint8Array bytes, int width, int height);
  external JSPromise<JSAny?> startCamera(JSFunction callback);
  external void flush();
  external JSPromise<JSAny?> dispose();
}

/// Browser output tracks are generated from the same bytes the analyzer sees.
class CaptureBridge {
  _Bridge? _bridge;

  Future<MediaStream> create() async {
    final bridge = _bridge = await _createBridge().toDart;
    return MediaStreamWeb(bridge.stream, 'local');
  }

  Future<void> startCamera(
    void Function(Uint8List bgra, int width, int height, int timestampUs)
    onFrame,
  ) async {
    await _bridge!
        .startCamera(
          ((
                JSUint8Array bytes,
                JSNumber width,
                JSNumber height,
                JSNumber timestamp,
              ) {
                onFrame(
                  bytes.toDart,
                  width.toDartInt,
                  height.toDartInt,
                  timestamp.toDartInt,
                );
              })
              .toJS,
        )
        .toDart;
  }

  Future<void> pushAudio(Uint8List bytes) async =>
      _bridge!.pushAudio(bytes.toJS);

  Future<void> pushVideo(
    Uint8List bgra,
    int width,
    int height,
    int timestampUs,
  ) async => _bridge!.pushVideo(bgra.toJS, width, height);

  Future<void> flush() async => _bridge!.flush();

  Future<void> dispose() async {
    await _bridge?.dispose().toDart;
    _bridge = null;
  }
}
