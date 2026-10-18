import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Writes the report next to the models so it can be collected from devices
/// (`devicectl` / `adb run-as` / the Windows profile) when print is not visible.
Future<String?> saveReport(String name, String json) async {
  final dir = await getApplicationSupportDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsString(json);
  return file.path;
}

void exitApp() => exit(0);
