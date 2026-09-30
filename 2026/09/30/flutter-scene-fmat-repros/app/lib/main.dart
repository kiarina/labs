// Minimal reproductions for flutter_scene .fmat issues.
//
// Each case is one object. The app draws the selected cases side by side,
// reads the rendered frame back, and prints the color at each object:
//
//   [repro] C expected blue, got blue (rgb ...) ok
//
// Custom vertex attributes (assets/materials/attr_probe.fmat reads `phase`
// and shows it: green = 0, blue = 1, red = anything else):
//   A  static cube,    attribute set to 1                  -> blue
//   B  static cube,    attribute not set                   -> green (docs: reads 0)
//   C  skinned model,  attribute set to 1                  -> blue
//   D  skinned model,  attribute not set                   -> green (docs: reads 0)
//   H  skinned model,  attribute set, each primitive also drawn with the
//      built-in PBR material over the same geometry (a shell over a base
//      pass, like a toon outline)                          -> blue
//   I  static cube,    attribute set, drawn only with the built-in PBR
//      material                                            -> orange
//   J  skinned model,  attribute set, drawn only with the built-in PBR
//      material                                            -> orange
// Sampler placeholders (assets/materials/hint_*.fmat output the unset sampler):
//   E  `hint: default_black`                               -> black
//   F  `hint: default_white`                               -> white
// Reference:
//   G  cube with the built-in PBR material                 -> orange
//
// Settings, from --dart-define or (desktop) an environment variable:
//   CASES=ACG     the cases to draw (default ACDEFG)
//   MODEL=<path>  the skinned model: an asset path or an absolute file path
//   SHADOW=1      add a shadow-casting directional light
//   OUT=<name>    also write the frame as PNG under the app's temp directory
//   EXIT=1        quit after reporting
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Material;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

String _setting(String name, String fromDefine) =>
    Platform.environment[name] ?? fromDefine;

final kCases = _setting(
  'CASES',
  const String.fromEnvironment('CASES', defaultValue: 'ACDEFG'),
);
final kModel = _setting(
  'MODEL',
  const String.fromEnvironment('MODEL', defaultValue: 'models/CesiumMan.glb'),
);
final kShadow =
    _setting('SHADOW', const String.fromEnvironment('SHADOW')) == '1';
final kOut = _setting('OUT', const String.fromEnvironment('OUT'));
final kExit = _setting('EXIT', const String.fromEnvironment('EXIT')) == '1';
// Echoed in the report, so a script can tell this run's report from an old one.
final kRunId = _setting('RUN_ID', const String.fromEnvironment('RUN_ID'));

const _expected = {
  'A': 'blue',
  'B': 'green',
  'C': 'blue',
  'D': 'green',
  'E': 'black',
  'F': 'white',
  'G': 'orange',
  'H': 'blue',
  'I': 'orange',
  'J': 'orange',
};
const _skinned = 'CDHJ';
const _spacing = 1.0;

void main() => runApp(const MaterialApp(home: ReproPage()));

class ReproPage extends StatefulWidget {
  const ReproPage({super.key});

  @override
  State<ReproPage> createState() => _ReproPageState();
}

class _ReproPageState extends State<ReproPage> {
  final scene = Scene();
  final camera = PerspectiveCamera(
    position: vm.Vector3(0, 1.0, -10),
    target: vm.Vector3(0, 0.8, 0),
    fovRadiansY: 35 * vm.degrees2Radians,
  );
  final _frameKey = GlobalKey();
  final List<String> cases = [
    for (final c in _expected.keys)
      if (kCases.contains(c)) c,
  ];
  String status = 'loading';

  @override
  void initState() {
    super.initState();
    _build();
  }

  // Cases are laid out left to right in alphabetical order (world -x is
  // screen left).
  double _x(String name) =>
      (cases.indexOf(name) - (cases.length - 1) / 2) * _spacing;

  Future<void> _build() async {
    await Scene.initializeStaticResources();
    scene.environment = EnvironmentMap.empty();
    if (kShadow) {
      scene.directionalLight = DirectionalLight(
        direction: vm.Vector3(-0.3, -1, -0.5)..normalize(),
        intensity: 3,
        castsShadow: true,
      );
    }
    Future<Material> probe() =>
        loadFmatMaterial('assets/materials/attr_probe.fmat');
    for (final name in cases) {
      switch (name) {
        case 'A':
          _addCube(name, await probe(), phase: 1);
        case 'B':
          _addCube(name, await probe());
        case 'C':
          await _addModel(name, phase: 1);
        case 'D':
          await _addModel(name);
        case 'E':
          _addCube(
            name,
            await loadFmatMaterial('assets/materials/hint_black.fmat'),
          );
        case 'F':
          _addCube(
            name,
            await loadFmatMaterial('assets/materials/hint_white.fmat'),
          );
        case 'G':
          _addCube(name, _pbr());
        case 'H':
          await _addModel(name, phase: 1, withBasePass: true);
        case 'I':
          _addCube(name, _pbr(), phase: 1);
        case 'J':
          await _addModel(name, phase: 1, probeMaterial: false);
      }
    }
    setState(() => status = 'ready');
    final report = File('${Directory.systemTemp.path}/fmat_report.txt');
    if (report.existsSync()) report.deleteSync();
    _record(
      '[repro] ready: cases ${cases.join()}, model $kModel, shadow $kShadow, run $kRunId',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await _report();
    _record('[repro] done');
    if (kExit) exit(0);
  }

  // Also appended to <temp>/fmat_report.txt, since a release build on a
  // device has no console to print to (copy it off with devicectl).
  static void _record(String line) {
    debugPrint(line);
    File(
      '${Directory.systemTemp.path}/fmat_report.txt',
    ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  static Material _pbr() => PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.9, 0.6, 0.1, 1)
    ..emissiveFactor = vm.Vector4(0.9, 0.6, 0.1, 1);

  static void _setPhase(Geometry geometry, double phase) {
    final count = geometry.extractMeshData().positions.length ~/ 3;
    geometry.setCustomAttribute(
      'phase',
      Float32List(count)..fillRange(0, count, phase),
      components: 1,
    );
  }

  void _addCube(String name, Material material, {double? phase}) {
    final geometry = CuboidGeometry(vm.Vector3(0.6, 0.6, 0.6));
    if (phase != null) _setPhase(geometry, phase);
    scene.add(
      Node(
        name: 'case $name',
        mesh: Mesh(geometry, material),
        localTransform: vm.Matrix4.translation(vm.Vector3(_x(name), 0.5, 0)),
      ),
    );
  }

  Future<Uint8List> _modelBytes() async {
    if (kModel.startsWith('/')) return File(kModel).readAsBytes();
    return (await rootBundle.load(kModel)).buffer.asUint8List();
  }

  Future<void> _addModel(
    String name, {
    double? phase,
    bool withBasePass = false,
    bool probeMaterial = true,
  }) async {
    final model = await Node.fromGlbBytes(await _modelBytes());
    final kinds = <String>{};
    for (final node in model.meshNodes) {
      final mesh = node.mesh!;
      for (final primitive in mesh.primitives.toList()) {
        kinds.add('${primitive.geometry.runtimeType}');
        if (withBasePass) {
          mesh.primitives.add(MeshPrimitive(primitive.geometry, _pbr()));
        }
        primitive.material = probeMaterial
            ? await loadFmatMaterial('assets/materials/attr_probe.fmat')
            : _pbr();
        if (phase != null) _setPhase(primitive.geometry, phase);
      }
    }
    debugPrint('[repro] case $name geometry: ${kinds.join(', ')}');
    scene.add(
      Node(
        name: 'case $name',
        localTransform: vm.Matrix4.translation(vm.Vector3(_x(name), 0, 0)),
      )..add(model),
    );
  }

  // Pulls the camera back far enough that every case fits the view width.
  void _fitCamera(Size size) {
    final halfWidth = (cases.length / 2) * _spacing + 0.3;
    final tanHalfFov = 0.3153; // tan(17.5 degrees)
    final distance = halfWidth / (tanHalfFov * size.width / size.height);
    camera.position = vm.Vector3(0, 1.0, -distance.clamp(6.0, 60.0));
  }

  // Reads back the rendered frame and reports the color at each case, so the
  // result does not depend on anyone looking at the window. "none" means
  // nothing was drawn there (the 3D view is transparent where it is empty).
  Future<void> _report() async {
    final boundary =
        _frameKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final w = image.width, h = image.height;
    final rgba = (await image.toByteData())!;
    if (kOut.isNotEmpty) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final path = '${Directory.systemTemp.path}/$kOut';
      File(path).writeAsBytesSync(png!.buffer.asUint8List());
      debugPrint('[repro] frame written to $path');
    }
    final view = vm.makeViewMatrix(camera.position, camera.target, camera.up);
    final proj = vm.makePerspectiveMatrix(
      camera.fovRadiansY,
      w / h,
      camera.fovNear,
      camera.fovFar,
    );
    for (final name in cases) {
      final y = _skinned.contains(name) ? 1.0 : 0.5;
      final clip = (proj * view as vm.Matrix4).transformed(
        vm.Vector4(_x(name), y, 0, 1),
      );
      // flutter_scene's view is mirrored against vector_math's right-handed
      // makeViewMatrix: world -x is screen left.
      final px = ((1 - ((clip.x / clip.w) * 0.5 + 0.5)) * w).round();
      final py = ((1 - ((clip.y / clip.w) * 0.5 + 0.5)) * h).round();
      final o = (py * w + px) * 4;
      final r = rgba.getUint8(o), g = rgba.getUint8(o + 1);
      final b = rgba.getUint8(o + 2), a = rgba.getUint8(o + 3);
      final got = a < 128 ? 'none' : _classify(r, g, b);
      _record(
        '[repro] $name expected ${_expected[name]}, got $got '
        '(rgb $r,$g,$b at $px,$py) '
        '${got == _expected[name] ? 'ok' : 'UNEXPECTED'}',
      );
    }
  }

  static String _classify(int r, int g, int b) {
    // Unlit output passes through tone mapping, so match the nearest.
    const named = {
      'blue': [0, 50, 255],
      'green': [0, 255, 0],
      'red': [255, 0, 0],
      'black': [0, 0, 0],
      'white': [255, 255, 255],
      'orange': [255, 170, 30],
    };
    var best = '', bestD = 1 << 30;
    named.forEach((k, v) {
      final d =
          (r - v[0]) * (r - v[0]) +
          (g - v[1]) * (g - v[1]) +
          (b - v[2]) * (b - v[2]);
      if (d < bestD) {
        bestD = d;
        best = k;
      }
    });
    return best;
  }

  @override
  Widget build(BuildContext context) {
    _fitCamera(MediaQuery.sizeOf(context));
    return Scaffold(
      backgroundColor: const Color(0xFF808080),
      body: RepaintBoundary(
        key: _frameKey,
        child: Stack(
          children: [
            Positioned.fill(child: SceneView(scene, camera: camera)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Row(
                children: [
                  for (final c in cases)
                    Expanded(
                      child: Text(
                        '$c\n${_expected[c]}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              left: 8,
              top: 48,
              child: Text(
                '$status  ${kShadow ? 'shadow' : ''}',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
