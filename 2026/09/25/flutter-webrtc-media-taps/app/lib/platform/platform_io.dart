import 'dart:convert';
import 'dart:io';

/// Desktop: `TAPS_<KEY>` environment variables. Android: intent extras
/// copied into the environment by MainActivity. iOS: `<tmp>/taps_config.json`
/// pushed with devicectl.
String? envValue(String key) =>
    Platform.environment['TAPS_${key.toUpperCase()}'] ??
    _config[key]?.toString();

final Map<String, Object?> _config = () {
  try {
    final file = File('${Directory.systemTemp.path}/taps_config.json');
    if (!file.existsSync()) return <String, Object?>{};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  } catch (_) {
    return <String, Object?>{};
  }
}();

/// iOS release builds do not forward print to the launching console, and
/// Android's log drops everything after ~1 KB of a line, so the result is
/// also written to the temp dir and printed in numbered chunks on Android.
void writeResult(String json) {
  try {
    File('${Directory.systemTemp.path}/taps_result.json')
        .writeAsStringSync(json);
  } catch (_) {}
  if (Platform.isAndroid) {
    const size = 800;
    final count = (json.length / size).ceil();
    for (var i = 0; i < count; i++) {
      final end = (i + 1) * size < json.length ? (i + 1) * size : json.length;
      // ignore: avoid_print
      print('TAPS_PART ${i + 1}/$count ${json.substring(i * size, end)}');
    }
  }
}

void exitApp() => exit(0);
