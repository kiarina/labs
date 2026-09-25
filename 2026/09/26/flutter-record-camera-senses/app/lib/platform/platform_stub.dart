import 'dart:typed_data';

/// Web: settings come from the page URL; the console line is the output.
String? envValue(String key) => Uri.base.queryParameters[key];

void writeResult(String json) {}

void exitApp() {}

/// Web: playback of the test signal is not measured (see README).
Future<String?> writeTempFile(String name, Uint8List bytes) async => null;
