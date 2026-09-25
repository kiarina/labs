import 'dart:convert';
import 'dart:io';

/// Native: `REALTIME_<KEY>` environment variables (desktop), or keys of
/// `<temp dir>/realtime_config.json` (mobile, pushed with devicectl / adb),
/// so one build can run every mode.
String? envValue(String key) =>
    Platform.environment['REALTIME_${key.toUpperCase()}'] ??
    _config[key]?.toString();

final Map<String, Object?> _config = () {
  try {
    final file = File('${Directory.systemTemp.path}/realtime_config.json');
    if (!file.existsSync()) return <String, Object?>{};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  } catch (_) {
    return <String, Object?>{};
  }
}();
