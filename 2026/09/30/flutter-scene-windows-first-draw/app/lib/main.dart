// Times the first frame that draws each kind of flutter_scene mesh.
//
// The app adds one mesh per step, waits for the frames that draw it, and
// writes one line per step: the wall time until the second frame after the
// add, and the longest UI (build) and raster durations among those frames.
// Built with --dart-define=FLUTTER_SCENE_PROFILE=true, flutter_scene also logs
// every pipeline build of 8 ms or more, and those lines go to the same file.
//
// Settings (environment variables; the Windows runner cannot take stdout, so
// everything goes to OUT):
//   STEPS=unlit,pbr,skinned,skinned   the meshes to add, in order (also
//                                     skinned_unlit: the model with UnlitMaterial)
//   SHADOW=1                          a shadow-casting directional light (default on)
//   IDLE_MS=1000                      the wait before each step
//   OUT=<path>                        the result file (default: temp/first_draw.txt)
import 'dart:io';

import 'package:flutter/material.dart' hide Material;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

final env = Platform.environment;
final steps = (env['STEPS'] ?? 'unlit,pbr,skinned,skinned').split(',');
final shadow = (env['SHADOW'] ?? '1') == '1';
final idle = Duration(milliseconds: int.parse(env['IDLE_MS'] ?? '1000'));
final out = File(
  env['OUT'] ??
      '${Directory.systemTemp.path}${Platform.pathSeparator}first_draw.txt',
);
final started = Stopwatch()..start();

void log(String line) {
  final stamped =
      '[${(started.elapsedMilliseconds / 1000).toStringAsFixed(2)}s] $line';
  stdout.writeln(stamped);
  out.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
}

void main() {
  if (out.existsSync()) out.deleteSync();
  debugPrint = (message, {wrapWidth}) => log(message ?? '');
  runApp(const MaterialApp(home: FirstDrawPage()));
}

class FirstDrawPage extends StatefulWidget {
  const FirstDrawPage({super.key});

  @override
  State<FirstDrawPage> createState() => _FirstDrawPageState();
}

class _FirstDrawPageState extends State<FirstDrawPage> {
  final scene = Scene();
  final camera = PerspectiveCamera(
    position: vm.Vector3(0, 1.2, -6),
    target: vm.Vector3(0, 0.8, 0),
  );
  final List<FrameTiming> _timings = [];
  String status = 'starting';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
    _run();
  }

  Future<void> _frames(int n) async {
    for (var i = 0; i < n; i++) {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  Future<Node> _step(String kind, int index) async {
    final x = -2.0 + index * 1.2;
    Node cube(Material material) => Node(
      name: kind,
      mesh: Mesh(CuboidGeometry(vm.Vector3(0.5, 0.5, 0.5)), material),
      localTransform: vm.Matrix4.translation(vm.Vector3(x, 0.5, 0)),
    );
    switch (kind) {
      case 'unlit':
        return cube(
          UnlitMaterial()..baseColorFactor = vm.Vector4(0.2, 0.6, 1, 1),
        );
      case 'pbr':
        return cube(
          PhysicallyBasedMaterial()
            ..baseColorFactor = vm.Vector4(0.9, 0.6, 0.1, 1),
        );
      case 'skinned' || 'skinned_unlit':
        final bytes = await rootBundle.load('models/CesiumMan.glb');
        final model = await Node.fromGlbBytes(bytes.buffer.asUint8List());
        if (kind == 'skinned_unlit') {
          for (final n in model.meshNodes) {
            for (final p in n.mesh!.primitives) {
              p.material = UnlitMaterial()
                ..baseColorFactor = vm.Vector4(0.2, 0.6, 1, 1);
            }
          }
        }
        return Node(
          name: kind,
          localTransform: vm.Matrix4.translation(vm.Vector3(x, 0, 0)),
        )..add(model);
    }
    throw ArgumentError('unknown step $kind');
  }

  Future<void> _run() async {
    log(
      'start: steps ${steps.join(',')}, shadow $shadow, ${Platform.operatingSystem}',
    );
    await Scene.initializeStaticResources();
    if (shadow) {
      scene.directionalLight = DirectionalLight(
        direction: vm.Vector3(-0.3, -1, -0.5)..normalize(),
        intensity: 3,
        castsShadow: true,
      );
    }
    scene.add(
      Node(
        name: 'floor',
        mesh: Mesh(
          CuboidGeometry(vm.Vector3(8, 0.02, 4)),
          PhysicallyBasedMaterial()
            ..baseColorFactor = vm.Vector4(0.8, 0.8, 0.8, 1),
        ),
      ),
    );
    setState(() => status = 'floor');
    await _frames(3);
    log('floor drawn');
    for (var i = 0; i < steps.length; i++) {
      await Future<void>.delayed(idle);
      await _frames(2);
      final node = await _step(steps[i], i);
      _timings.clear();
      final watch = Stopwatch()..start();
      scene.add(node);
      setState(() => status = 'step ${i + 1}: ${steps[i]}');
      await _frames(2);
      watch.stop();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      int maxMs(Duration Function(FrameTiming) f) => _timings.isEmpty
          ? -1
          : _timings
                .map((t) => f(t).inMilliseconds)
                .reduce((a, b) => a > b ? a : b);
      log(
        'step ${i + 1} ${steps[i]}: ${watch.elapsedMilliseconds} ms to draw '
        '(max build ${maxMs((t) => t.buildDuration)} ms, '
        'max raster ${maxMs((t) => t.rasterDuration)} ms)',
      );
    }
    log('done');
    if ((env['EXIT'] ?? '1') == '1') exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: SceneView(scene, camera: camera)),
          Positioned(left: 8, top: 8, child: Text(status)),
        ],
      ),
    );
  }
}
