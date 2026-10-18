import 'dart:io';

import 'package:path_provider/path_provider.dart';

String get platformName => Platform.operatingSystem;

Map<String, Object?> hostInfo() => {
      'platform': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'processors': Platform.numberOfProcessors,
      'dart': Platform.version.split(' ').first,
    };

/// Resident set size of this process, MiB.
double? rssMb() => ProcessInfo.currentRss / (1 << 20);

/// Writes the report into the app's support directory (collected with
/// devicectl / simctl / the Windows profile / the macOS container).
Future<String?> saveReport(String name, String json) async {
  final dir = await getApplicationSupportDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsString(json);
  return file.path;
}

void exitApp() => exit(0);
