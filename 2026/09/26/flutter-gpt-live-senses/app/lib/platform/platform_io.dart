import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Desktop: `LIVE_<KEY>` environment variables. Android: intent extras
/// copied into the environment by MainActivity. iOS: `<tmp>/live_config.json`
/// pushed with devicectl.
String? envValue(String key) =>
    Platform.environment['LIVE_${key.toUpperCase()}'] ??
    _config[key]?.toString();

final Map<String, Object?> _config = () {
  try {
    final file = File('${Directory.systemTemp.path}/live_config.json');
    if (!file.existsSync()) return <String, Object?>{};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  } catch (_) {
    return <String, Object?>{};
  }
}();

/// iOS release builds do not forward print to the launching console and
/// Android's log drops everything after ~1 KB of a line, so the result is also
/// written to the temp dir and printed in numbered chunks on Android.
void writeResult(String json) {
  try {
    File('${Directory.systemTemp.path}/live_result.json')
        .writeAsStringSync(json);
  } catch (_) {}
  if (Platform.isAndroid) {
    // logcat cuts a line at ~1 KB of bytes, not characters: escape non-ASCII
    // (Japanese transcripts are 3 bytes per character in UTF-8) first.
    json = _asciiJson(json);
    const size = 800;
    final count = (json.length / size).ceil();
    for (var i = 0; i < count; i++) {
      final end = (i + 1) * size < json.length ? (i + 1) * size : json.length;
      // ignore: avoid_print
      print('LIVE_PART ${i + 1}/$count ${json.substring(i * size, end)}');
    }
  }
}

String _asciiJson(String json) {
  final b = StringBuffer();
  for (final unit in json.codeUnits) {
    if (unit < 0x80) {
      b.writeCharCode(unit);
    } else {
      b.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    }
  }
  return b.toString();
}

void exitApp() => exit(0);

Future<String?> writeTempFile(String name, Uint8List bytes) async {
  final file = File('${Directory.systemTemp.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
