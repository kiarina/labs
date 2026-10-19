import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

@JS('createAecAudio')
external JSPromise<_Backend> _create();

extension type _Backend(JSObject _) implements JSObject {
  external void configure(JSObject options);
  external void render(JSUint8Array bytes);
  external JSPromise<JSAny?> stopRender();
  external JSUint8Array renderTrace();
  external JSUint8Array capture(JSUint8Array bytes);
  external JSString stats();
  external JSPromise<JSAny?> dispose();
}

class AecAudio {
  _Backend? _backend;
  Future<void> configure({bool enabled = true, int delayMs = 80}) async {
    final backend = _backend ??= await _create().toDart;
    backend.configure(
      {'enabled': enabled, 'delayMs': delayMs}.jsify()! as JSObject,
    );
  }

  Future<void> render(Uint8List bytes) async => _backend!.render(bytes.toJS);
  Future<void> stopRender() async => await _backend!.stopRender().toDart;
  Future<Uint8List> renderTrace() async => _backend!.renderTrace().toDart;
  Future<Uint8List> capture(Uint8List bytes) async =>
      _backend!.capture(bytes.toJS).toDart;
  Future<Map<String, dynamic>> stats() async =>
      jsonDecode(_backend!.stats().toDart) as Map<String, dynamic>;
  Future<void> dispose() async {
    await _backend?.dispose().toDart;
    _backend = null;
  }
}
