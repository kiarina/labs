import 'dart:io';
import 'dart:typed_data';

String platformName() => Platform.operatingSystem;

/// Desktop: `ECHO_CONFIG`. Android: the `config` intent extra, exported to
/// `ECHO_CONFIG` by MainActivity. iOS: `<tmp>/echo_config.json` pushed with
/// devicectl.
String? configJson() {
  final env = Platform.environment['ECHO_CONFIG'];
  if (env != null && env.isNotEmpty) return env;
  final file = File('${Directory.systemTemp.path}/echo_config.json');
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// Also written to the temp dir (iOS release builds do not forward print) and
/// printed in numbered chunks (Android's log cuts lines at ~1 KB).
void writeResult(String json) {
  try {
    File('${Directory.systemTemp.path}/echo_result.json').writeAsStringSync(json);
  } catch (_) {}
  const size = 800;
  final count = (json.length / size).ceil();
  for (var i = 0; i < count; i++) {
    final end = (i + 1) * size < json.length ? (i + 1) * size : json.length;
    // ignore: avoid_print
    print('ECHO_PART ${i + 1}/$count ${json.substring(i * size, end)}');
  }
}

void exitApp() => exit(0);

/// Recordings stay on the device (temp dir) for listening; they are not
/// committed.
Future<void> saveRecording(String name, Uint8List wav) async {
  final dir = Directory('${Directory.systemTemp.path}/echo_recordings');
  await dir.create(recursive: true);
  await File('${dir.path}/$name').writeAsBytes(wav, flush: true);
}
