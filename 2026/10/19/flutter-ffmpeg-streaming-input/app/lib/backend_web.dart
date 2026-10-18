import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;
import 'package:audio_analysis/audio_analysis.dart';

import 'stream_types.dart';

@JS('streamMedia')
external JSPromise<JSAny?> _stream(
  JSNumber seconds,
  JSNumber delay,
  JSNumber cancelAt,
  JSFunction onEvent,
);
Future<OnnxModel> loadVad() =>
    defaultOnnxBackend(threads: 1).load('assets/assets/silero_vad.onnx');
Future<Map<String, Object?>> streamDecode(
  StreamCase c,
  Future<void> Function(Uint8List, double) audio,
  Future<void> Function(Uint8List, double) image,
) async {
  final callback = ((JSNumber kind, JSUint8Array data, JSNumber pts) {
    return (kind.toDartInt == 1
            ? audio(data.toDart, pts.toDartDouble)
            : image(data.toDart, pts.toDartDouble))
        .toJS;
  }).toJS;
  final result = await _stream(
    c.durationSeconds.toJS,
    c.delayMs.toJS,
    c.cancelAfterSeconds.toJS,
    callback,
  ).toDart;
  return (result.dartify() as Map).cast<String, Object?>();
}

Map<String, int> memory() {
  final m = (globalContext['performance'] as JSObject)['memory'];
  if (m == null || m.isUndefinedOrNull) return {};
  final o = m as JSObject;
  return {'js_heap_used': (o['usedJSHeapSize'] as JSNumber).toDartInt};
}

Future<void> saveReport(Map<String, Object?> r) async {
  web.window.localStorage.setItem('stream-report', jsonEncode(r));
  await web.window
      .fetch(
        '/report'.toJS,
        web.RequestInit(
          method: 'POST',
          body: web.Blob(
            [jsonEncode(r).toJS].toJS,
            web.BlobPropertyBag(type: 'application/json'),
          ),
        ),
      )
      .toDart;
}

void done() {}
String get platform => 'web';
String get cases =>
    Uri.base.queryParameters['cases'] ??
    const String.fromEnvironment(
      'CASES',
      defaultValue: '60,600,slow,cancel,restart',
    );
