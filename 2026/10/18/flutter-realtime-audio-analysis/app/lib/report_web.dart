import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// On the web the report goes to the console and to `window.resultJson`
/// (with `done: true`), which packages/whisper_cpp/web/harness/run_headless.mjs
/// waits for.
Future<String?> saveReport(String name, String json) async {
  final report = jsonDecode(json) as Map<String, dynamic>;
  globalContext['resultJson'] = jsonEncode({...report, 'done': true}).toJS;
  return null;
}

void exitApp() {}
