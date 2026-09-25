import 'dart:io';

void exitApp() => exit(0);

/// Release builds on iOS do not forward Dart `print` to the launching
/// console, so the result is also written to the app's temp directory, from
/// where `devicectl device copy from` can fetch it.
void writeResultFile(String json) {
  try {
    File(
      '${Directory.systemTemp.path}/realtime_result.json',
    ).writeAsStringSync(json);
  } catch (_) {}
}

/// Android's log drops everything after ~1 KB of a single `print`, so the
/// result is also printed in numbered chunks there.
void printResultChunks(String json) {
  if (!Platform.isAndroid) return;
  const size = 800;
  final count = (json.length / size).ceil();
  for (var i = 0; i < count; i++) {
    final end = (i + 1) * size < json.length ? (i + 1) * size : json.length;
    // ignore: avoid_print
    print('REALTIME_PART ${i + 1}/$count ${json.substring(i * size, end)}');
  }
}
