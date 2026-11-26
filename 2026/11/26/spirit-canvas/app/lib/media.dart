import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

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
  'VRM_DIR': String.fromEnvironment('VRM_DIR'),
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
/// test assets), the VRM at VRM_PATH ("default") and the .vrm files in the
/// folders of VRM_DIR (by file name, for several bodies; Part 15). Both come from the environment
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
    // 3D models (glTF binary), for a world's `model` (Part 13).
    'model': ['.glb'],
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
      'vrm': [if (vrmPath.isNotEmpty) 'default', ..._vrmNames().keys],
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

  /// The .vrm files in VRM_DIR, by file name.
  Map<String, String> _vrmNames() => {
    for (final d in env('VRM_DIR').split(':'))
      if (d.isNotEmpty && Directory(d).existsSync())
        for (final f
            in Directory(d).listSync().whereType<File>().toList()
              ..sort((a, b) => a.path.compareTo(b.path)))
          if (f.path.toLowerCase().endsWith('.vrm'))
            f.uri.pathSegments.last: f.path,
  };

  File? vrmFile(String? src) {
    final path = src == null || src.isEmpty || src == 'default'
        ? vrmPath
        : (_vrmNames()[src] ?? src);
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

  /// For each model: its size in metres in a world (w across, h up, d
  /// deep, at scale 1), where its bottom is relative to its origin, and the
  /// names of its animations. Read from the glTF's own description.
  Map<String, Object> modelInfo() => {
    for (final name in list()['model'] ?? const <String>[])
      if (resolve(name)?.file case final f?) name: _glbInfo(f),
  };

  static Object _glbInfo(File f) {
    try {
      final b = f.readAsBytesSync();
      final d = ByteData.sublistView(b);
      final n = d.getUint32(12, Endian.little);
      final j = jsonDecode(
        utf8.decode(b.sublist(20, 20 + n)),
      ) as Map<String, dynamic>;
      final nodes = (j['nodes'] as List?) ?? const [];
      final meshes = (j['meshes'] as List?) ?? const [];
      final accessors = (j['accessors'] as List?) ?? const [];
      final lo = vm.Vector3.all(double.infinity);
      final hi = vm.Vector3.all(double.negativeInfinity);
      vm.Vector3 v3(List l) => vm.Vector3(
        (l[0] as num).toDouble(),
        (l[1] as num).toDouble(),
        (l[2] as num).toDouble(),
      );
      void visit(int i, vm.Matrix4 parent) {
        final node = nodes[i] as Map<String, dynamic>;
        final vm.Matrix4 local;
        if (node['matrix'] case final List m) {
          local = vm.Matrix4.fromList([
            for (final x in m) (x as num).toDouble(),
          ]);
        } else {
          final t = node['translation'] as List?;
          final r = node['rotation'] as List?;
          final s = node['scale'] as List?;
          local = vm.Matrix4.compose(
            t == null ? vm.Vector3.zero() : v3(t),
            r == null
                ? vm.Quaternion.identity()
                : vm.Quaternion(
                    (r[0] as num).toDouble(),
                    (r[1] as num).toDouble(),
                    (r[2] as num).toDouble(),
                    (r[3] as num).toDouble(),
                  ),
            s == null ? vm.Vector3.all(1) : v3(s),
          );
        }
        final m = parent * local;
        if (node['mesh'] case final int mi) {
          for (final p in (meshes[mi]['primitives'] as List)) {
            final a = accessors[p['attributes']['POSITION'] as int];
            final mn = v3(a['min'] as List), mx = v3(a['max'] as List);
            for (var c = 0; c < 8; c++) {
              final corner = vm.Vector3(
                c & 1 == 0 ? mn.x : mx.x,
                c & 2 == 0 ? mn.y : mx.y,
                c & 4 == 0 ? mn.z : mx.z,
              );
              final w = m.transformed3(corner);
              lo.setValues(
                w.x < lo.x ? w.x : lo.x,
                w.y < lo.y ? w.y : lo.y,
                w.z < lo.z ? w.z : lo.z,
              );
              hi.setValues(
                w.x > hi.x ? w.x : hi.x,
                w.y > hi.y ? w.y : hi.y,
                w.z > hi.z ? w.z : hi.z,
              );
            }
          }
        }
        for (final c in (node['children'] as List?) ?? const []) {
          visit(c as int, m);
        }
      }

      final scene = (j['scenes'] as List)[(j['scene'] as int?) ?? 0];
      for (final r in scene['nodes'] as List) {
        visit(r as int, vm.Matrix4.identity());
      }
      double r2(double x) => double.parse(x.toStringAsFixed(2));
      return {
        'size_m': [r2(hi.x - lo.x), r2(hi.y - lo.y), r2(hi.z - lo.z)],
        'bottom_m': r2(lo.y),
        'animations': [
          for (final a in (j['animations'] as List?) ?? const []) a['name'],
        ],
        'textured': ((j['images'] as List?) ?? const []).isNotEmpty,
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }
}
