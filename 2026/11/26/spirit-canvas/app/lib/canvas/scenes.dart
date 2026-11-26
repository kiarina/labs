import 'dart:convert';
import 'dart:io';

/// Saved screens: one JSON file each. Ready-made ones ship with the lab
/// (SCENES_DIR, in Git); the spirit's own go to SAVED_SCENES_DIR. A name in
/// both is the spirit's.
///
/// A scene: `{name, description, params: {key: {description, default}},
/// background, elements, state, timelines: {id: {steps, repeat, cycle_ms,
/// start}}, scripts: {id: code}, bgm: {src, volume}}`. Loading puts it on a
/// cleared canvas with `state` = its state, then the params' defaults, then
/// the values given; texts show them as {{key}} and scripts read them with
/// `sg.get(key)`.
class SceneStore {
  SceneStore({required this.builtinDir, required this.savedDir});

  final String builtinDir;
  final String savedDir;

  static final validName = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  Iterable<(File, String)> _files() sync* {
    for (final (dir, source) in [
      (builtinDir, 'ready-made'),
      (savedDir, 'saved'),
    ]) {
      final d = Directory(dir);
      if (dir.isEmpty || !d.existsSync()) continue;
      for (final f in d.listSync().whereType<File>()) {
        if (f.path.endsWith('.json')) yield (f, source);
      }
    }
  }

  /// What the spirit sees to choose one: name, description, params, source.
  List<Map<String, dynamic>> list() {
    final byName = <String, Map<String, dynamic>>{};
    for (final (f, source) in _files()) {
      try {
        final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final name =
            m['name'] as String? ??
            f.uri.pathSegments.last.replaceAll('.json', '');
        byName[name] = {
          'name': name,
          'description': m['description'],
          'params': m['params'] ?? const {},
          'source': source,
          'bytes': f.lengthSync(),
        };
      } on Object catch (e) {
        byName[f.path] = {'name': f.uri.pathSegments.last, 'error': '$e'};
      }
    }
    return byName.values.toList()
      ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
  }

  Map<String, dynamic>? read(String name) {
    for (final dir in [savedDir, builtinDir]) {
      final f = File('$dir/$name.json');
      if (dir.isNotEmpty && f.existsSync()) {
        return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      }
    }
    return null;
  }

  /// Writes the spirit's scene. Returns its size in bytes.
  int write(String name, Map<String, dynamic> scene) {
    if (!validName.hasMatch(name)) {
      throw ArgumentError('name must be lowercase letters, digits, - or _');
    }
    if (savedDir.isEmpty) throw StateError('no SAVED_SCENES_DIR');
    final f = File('$savedDir/$name.json');
    f.parent.createSync(recursive: true);
    final text = const JsonEncoder.withIndent(' ').convert(scene);
    f.writeAsStringSync('$text\n');
    return f.lengthSync();
  }
}
