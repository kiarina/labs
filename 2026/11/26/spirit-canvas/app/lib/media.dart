import 'dart:io';

/// A setting from the environment the lab's `run` task starts the app with.
String env(String name, [String fallback = '']) {
  final v = Platform.environment[name];
  return v == null || v.isEmpty ? fallback : v;
}

/// The media the spirit may show: files under MEDIA_DIR (the labs shared
/// test assets) and the VRM at VRM_PATH. Both come from the environment
/// the lab's `run` task sets, so nothing here names a local path.
class MediaLibrary {
  MediaLibrary._(this.dir, this.vrmPath, this.vrmaPath);

  static MediaLibrary? _instance;
  static MediaLibrary get instance => _instance ??= MediaLibrary._(
    env('MEDIA_DIR'),
    env('VRM_PATH'),
    env('VRMA_PATH'),
  );

  final String dir;
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
    final root = Directory(dir);
    if (dir.isNotEmpty && root.existsSync()) {
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
      if (dir.isNotEmpty) '$dir/$src',
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
