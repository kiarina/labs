import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

String get platformName => 'web';

Map<String, Object?> hostInfo() {
  final nav = globalContext['navigator'] as JSObject;
  return {
    'platform': 'web',
    'os_version': (nav['userAgent'] as JSString).toDart,
    'processors': (nav['hardwareConcurrency'] as JSNumber?)?.toDartInt,
    'cross_origin_isolated': (globalContext['crossOriginIsolated'] as JSBoolean?)?.toDart,
  };
}

/// Chrome's JS heap (performance.memory), MiB; the wasm memory of ONNX
/// Runtime is not in it.
double? rssMb() {
  final perf = globalContext['performance'] as JSObject;
  final mem = perf['memory'] as JSObject?;
  final used = mem?['usedJSHeapSize'] as JSNumber?;
  return used == null ? null : used.toDartDouble / (1 << 20);
}

/// The report goes to `window.resultJson` (with `done: true`), which
/// tools/run_headless.mjs waits for.
Future<String?> saveReport(String name, String json) async {
  final report = jsonDecode(json) as Map<String, dynamic>;
  globalContext['resultJson'] = jsonEncode({...report, 'done': true}).toJS;
  return null;
}

void exitApp() {}
