import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

String platformName() => 'web';

/// `?config=<base64url JSON>`.
String? configJson() {
  final raw = Uri.base.queryParameters['config'];
  if (raw == null) return null;
  return utf8.decode(base64Url.decode(base64Url.normalize(raw)));
}

@JS('__echoResult')
external set _echoResult(JSString value);

void writeResult(String json) {
  _echoResult = json.toJS;
  // ignore: avoid_print
  print('ECHO_RESULT $json');
  web.document.title = 'ECHO_DONE';
  // The lab's local server (tools/run.py) stores the posted result.
  web.window.fetch(
    '/result'.toJS,
    web.RequestInit(method: 'POST', body: json.toJS),
  );
}

void exitApp() {}

Future<void> saveRecording(String name, Uint8List wav) async {}
