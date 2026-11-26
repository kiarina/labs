import 'dart:io';

/// A setting from the environment the lab's `run` task starts the app with
/// (macOS), else from `--dart-define` (iOS and Android, where `flutter run`
/// starts the app).
String env(String name, [String fallback = '']) {
  final v = Platform.environment[name];
  if (v != null && v.isNotEmpty) return _inApp(v);
  final d = _defines[name];
  return d == null || d.isEmpty ? fallback : _inApp(d);
}

/// `@app/...` is a path in the app's own folder (the parent of its temporary
/// folder: the container on iOS, `/data/user/0/<package>` on Android), for
/// settings given at build time before that folder's path is known. Paths
/// separated by `:` each get it.
String _inApp(String v) {
  if (!v.contains('@app/')) return v;
  final root = Directory.systemTemp.parent.path;
  return v
      .split(':')
      .map((p) => p.startsWith('@app/') ? '$root/${p.substring(5)}' : p)
      .join(':');
}

const _defines = {
  'MEDIA_DIR': String.fromEnvironment('MEDIA_DIR'),
  'VRM_PATH': String.fromEnvironment('VRM_PATH'),
  'VRMA_PATH': String.fromEnvironment('VRMA_PATH'),
  'SCENES_DIR': String.fromEnvironment('SCENES_DIR'),
  'SAVED_SCENES_DIR': String.fromEnvironment('SAVED_SCENES_DIR'),
  'LOG_DIR': String.fromEnvironment('LOG_DIR'),
  'MODEL': String.fromEnvironment('MODEL'),
  'EFFORT': String.fromEnvironment('EFFORT'),
  'CONTROL_PORT': String.fromEnvironment('CONTROL_PORT'),
  'START_MODE': String.fromEnvironment('START_MODE'),
  'ABBREVIATE_VIEW': String.fromEnvironment('ABBREVIATE_VIEW'),
  'SELF_TEST': String.fromEnvironment('SELF_TEST'),
};

/// The media the spirit may show: files under MEDIA_DIR (the labs shared
/// test assets) and the VRM at VRM_PATH. Both come from the environment
/// the lab's `run` task sets, so nothing here names a local path.
class MediaLibrary {
  MediaLibrary._(String dirs, this.vrmPath, this.vrmaPath)
    : dirs = [
        for (final d in dirs.split(':'))
          if (d.isNotEmpty) d,
      ];

  static MediaLibrary? _instance;
  static MediaLibrary get instance => _instance ??= MediaLibrary._(
    env('MEDIA_DIR'),
    env('VRM_PATH'),
    env('VRMA_PATH'),
  );

  /// MEDIA_DIR: one folder, or several separated by `:` (the shared test
  /// assets, and the lab's own generated sounds). Names are relative to
  /// whichever folder holds them.
  final List<String> dirs;
  final String vrmPath;
  final String vrmaPath;

  static const _kinds = {
    'image': ['.jpg', '.jpeg', '.png', '.gif', '.webp'],
    'video': ['.mp4', '.mov'],
    'audio': ['.mp3', '.wav', '.m4a'],
  };

  /// `{kind: [name, ...]}`; names are paths relative to MEDIA_DIR.
  Map<String, List<String>> list() {
    final out = {for (final k in _kinds.keys) k: <String>[]};
    for (final dir in dirs) {
      final root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final f in root.listSync(recursive: true).whereType<File>()) {
        final name = f.path.substring(root.path.length + 1);
        final lower = name.toLowerCase();
        for (final MapEntry(:key, :value) in _kinds.entries) {
          if (value.any(lower.endsWith)) out[key]!.add(name);
        }
      }
    }
    for (final v in out.values) {
      v.sort();
    }
    return {
      ...out,
      'vrm': [if (vrmPath.isNotEmpty) 'default'],
      'vrma': [if (vrmaPath.isNotEmpty) 'default'],
    };
  }

  /// A URL as it is, else a file: a library name, or an absolute path.
  /// Null if no such file.
  ({String? url, File? file})? resolve(String? src) {
    if (src == null || src.isEmpty) return null;
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return (url: src, file: null);
    }
    for (final candidate in [
      for (final dir in dirs) '$dir/$src',
      if (src.startsWith('/')) src,
    ]) {
      final f = File(candidate);
      if (f.existsSync()) return (url: null, file: f);
    }
    return null;
  }

  File? vrmFile(String? src) {
    final path = src == null || src.isEmpty || src == 'default' ? vrmPath : src;
    final f = File(path);
    return path.isNotEmpty && f.existsSync() ? f : null;
  }

  File? vrmaFile(String? src) {
    final path = src == null || src.isEmpty || src == 'default'
        ? vrmaPath
        : src;
    final f = File(path);
    return path.isNotEmpty && f.existsSync() ? f : null;
  }
}
