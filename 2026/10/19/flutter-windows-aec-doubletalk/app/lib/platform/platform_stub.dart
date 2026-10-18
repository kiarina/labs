import 'dart:js_interop';

@JS('resultJson')
external set _resultJson(JSString value);

/// Web: settings come from the page URL; CDP can collect the final JSON.
String? envValue(String key) => Uri.base.queryParameters[key];

void writeResult(String json) => _resultJson = json.toJS;

void exitApp() {}

void writeStatus(String status) {}
