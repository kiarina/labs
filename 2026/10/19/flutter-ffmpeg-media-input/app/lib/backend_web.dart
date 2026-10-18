import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;
import 'package:audio_analysis/audio_analysis.dart';

@JS('decodeMedia')
external JSPromise<JSAny?> _decode(JSUint8Array input);
Future<OnnxModel> loadVad() =>
    defaultOnnxBackend(threads: 1).load('assets/assets/silero_vad.onnx');
Future<Map<String, Object?>> decode(
  Future<void> Function(Uint8List) audio,
  Future<void> Function(Uint8List, double) image,
) async {
  final b = await rootBundle.load('assets/input.mp4');
  final raw = (await _decode(b.buffer.asUint8List().toJS).toDart) as JSObject;
  final r = raw.dartify() as Map;
  final pcm = r.remove('pcm') as Uint8List;
  for (final f in r['frames'] as List) {
    await image(f.remove('jpeg') as Uint8List, (f['pts'] as num).toDouble());
  }
  for (var i = 0; i < pcm.length; i += 3199) {
    await audio(Uint8List.sublistView(pcm, i, (i + 3199).clamp(0, pcm.length)));
  }
  return {...r.cast<String, Object?>(), 'pcm_bytes': pcm.length};
}

Future<void> saveReport(Map<String, Object?> r) async {
  web.window.localStorage.setItem('media-report', jsonEncode(r));
  final body = web.Blob(
    [jsonEncode(r).toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  await web.window
      .fetch('/report'.toJS, web.RequestInit(method: 'POST', body: body))
      .toDart;
}

void done() {}
String get platform => 'web';

String get autoMode =>
    Uri.base.queryParameters['mode'] ?? const String.fromEnvironment('AUTO');
