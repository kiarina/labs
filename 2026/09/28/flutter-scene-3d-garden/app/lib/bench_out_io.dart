import 'dart:io';

/// Desktop GUI apps (Windows in particular) have no stdout to collect, so the
/// bench result also goes to a file: `BENCH_OUT`, or the temp directory.
void writeBenchResult(String json) {
  try {
    final path =
        Platform.environment['BENCH_OUT'] ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'scene_garden_bench.json';
    File(path).writeAsStringSync(json);
  } on Object {
    // Mobile sandboxes may refuse; the console line still carries it.
  }
}
