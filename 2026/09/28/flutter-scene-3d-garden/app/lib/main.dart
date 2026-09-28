import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'bench_out.dart';
import 'camera_rig.dart';
import 'garden.dart';
import 'vrm_avatar.dart';

/// Build-time settings (`--dart-define`).
const int kAvatars = int.fromEnvironment('AVATARS', defaultValue: 5);
const int kBodyRooms = int.fromEnvironment('ROOMS', defaultValue: 2);
const bool kBench = bool.fromEnvironment('BENCH');
const bool kTour = bool.fromEnvironment('TOUR');

/// Skip per-frame avatar posing (to separate Dart pose cost from drawing).
const bool kFreeze = bool.fromEnvironment('FREEZE');

/// Render resolution relative to logical pixels (0 = device pixel ratio).
final double kPixelRatio =
    double.tryParse(const String.fromEnvironment('PIXEL_RATIO')) ?? 0;

/// Anti-aliasing mode name (auto, none, msaa, fxaa, ...).
const String kAntiAliasing = String.fromEnvironment('AA', defaultValue: 'auto');
const bool kShadows = bool.fromEnvironment('SHADOWS', defaultValue: true);

const List<String> kVrmFiles = [
  'miineko.vrm',
  'AvatarSample_A.vrm',
  'AvatarSample_B.vrm',
  'AvatarSample_C.vrm',
  'AvatarSample_D.vrm',
];

void main() => runApp(const GardenApp());

class GardenApp extends StatelessWidget {
  const GardenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const GardenPage(),
    );
  }
}

class GardenPage extends StatefulWidget {
  const GardenPage({super.key});

  @override
  State<GardenPage> createState() => _GardenPageState();
}

class _GardenPageState extends State<GardenPage> {
  final Scene scene = Scene();
  final Garden garden = Garden(kBodyRooms);
  late final CameraRig rig;
  final List<VrmAvatar> avatars = [];
  final FrameStats stats = FrameStats();
  final FocusNode keyFocus = FocusNode();
  final List<String> log = [];

  bool ready = false;
  String status = 'initializing';
  Size viewSize = Size.zero;
  double devicePixelRatio = 1;
  int avatarTarget = kAvatars;
  bool loading = false;
  String lastInput = '-';
  String pickMethod = '-';

  // Gesture bookkeeping.
  double _lastScale = 1;
  double _lastRotation = 0;
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _log(String s) {
    debugPrint('[garden] $s');
    setState(() {
      log.add(s);
      if (log.length > 4) log.removeAt(0);
    });
  }

  String textureCap = '?';

  Future<void> _init() async {
    final sw = Stopwatch()..start();
    try {
      final m = jsonDecode(
        await rootBundle.loadString('assets/vrm/manifest.json'),
      );
      textureCap = '${(m as Map)['maxEdge']}';
    } on Object {
      textureCap = 'unknown';
    }
    try {
      await Scene.initializeStaticResources();
    } on Object catch (e) {
      setState(() => status = 'static resources failed: $e');
      return;
    }
    final staticMs = sw.elapsedMilliseconds;
    garden.build();
    scene.add(garden.root);
    scene.directionalLight = DirectionalLight(
      direction: vm.Vector3(-0.45, -1, -0.3)..normalize(),
      intensity: 3.2,
      castsShadow: kShadows,
      shadowMaxDistance: 40,
    );
    scene.antiAliasingMode = AntiAliasingMode.values.firstWhere(
      (m) => m.name == kAntiAliasing,
    );
    rig = CameraRig(target: garden.center, distance: garden.extent * 1.25);
    stats.resetWindow();
    _log(
      'static ${staticMs}ms, garden built ${sw.elapsedMilliseconds}ms '
      '(${defaultTargetPlatform.name}${kIsWeb ? '/web' : ''})',
    );
    setState(() {
      ready = true;
      status = 'loading avatars';
    });
    await _syncAvatars();
    if (kBench) unawaited(_runBench());
    if (kTour) unawaited(_runTour());
  }

  final Map<String, Uint8List> _bytes = {};

  Future<Uint8List> _vrmBytes(String file) async {
    return _bytes[file] ??= (await rootBundle.load('assets/vrm/$file')).buffer
        .asUint8List();
  }

  Future<void> _syncAvatars() async {
    if (loading) return;
    loading = true;
    try {
      while (avatars.length > avatarTarget) {
        final a = avatars.removeLast();
        scene.remove(a.root);
        scene.remove(a.pickProxy);
        if (rig.subject == a) rig.backToQuarter();
      }
      while (avatars.length < avatarTarget) {
        final i = avatars.length;
        final file = kVrmFiles[i % kVrmFiles.length];
        final bytes = await _vrmBytes(file);
        final sw = Stopwatch()..start();
        final a = await VrmAvatar.load(
          '${file.replaceAll('.vrm', '')}#$i',
          bytes,
        );
        final spot = garden.spots[i % garden.spots.length];
        a
          ..activity = spot.activity
          ..position =
              spot.position.clone() +
              (i >= garden.spots.length
                  ? vm.Vector3(0.9 * (i ~/ garden.spots.length), 0, 0)
                  : vm.Vector3.zero())
          ..yaw = spot.yaw
          ..seatHeight = spot.seatHeight;
        scene.add(a.root);
        scene.add(a.pickProxy);
        avatars.add(a);
        _log(
          '${a.label}: import ${a.loadMilliseconds}ms '
          '(json ${a.parseMilliseconds}ms), total ${sw.elapsedMilliseconds}ms'
          ' @${spot.name}',
        );
      }
    } on Object catch (e, st) {
      _log('avatar load failed: $e');
      debugPrint('$st');
    } finally {
      loading = false;
      if (mounted) setState(() => status = '${avatars.length} avatars');
    }
    if (avatars.length != avatarTarget) await _syncAvatars();
  }

  final Stopwatch _frameClock = Stopwatch()..start();

  void _onTick(Duration elapsed, double engineDt) {
    // Measure frame intervals with our own clock: the engine's delta source
    // differs between flutter_scene versions (0.24-dev reports 0 on web).
    final dt = _frameClock.elapsedMicroseconds / 1e6;
    _frameClock.reset();
    stats.add(dt);
    for (final a in avatars) {
      a.lookTarget = (rig.subject == a && rig.mode == CameraMode.focus)
          ? rig.camera.position
          : null;
      if (!kFreeze || !a.posedOnce) a.update(dt);
    }
    rig.update(dt);
    garden.updateCutaway(
      rig.forwardFlat,
      enabled: rig.mode == CameraMode.quarter || rig.transitioning,
    );
    if (stats.shouldRefresh) setState(() {});
  }

  // ---- picking ------------------------------------------------------------

  void _tap(Offset pos) {
    final ray = rig.camera.screenPointToRay(pos, viewSize);
    // Skinned meshes raycast at rest pose in flutter_scene 0.23, so a
    // seated avatar is picked through an invisible capsule that follows its
    // hips and head.
    final hit = scene.raycast(
      ray,
      includeInvisible: true,
      where: (n) => n.name.startsWith('__pick_'),
    );
    VrmAvatar? picked;
    if (hit != null) {
      picked = avatars.firstWhere((a) => a.pickProxy == hit.node);
      pickMethod = 'proxy raycast';
    } else {
      // Fallback: nearest head on screen within 60 px.
      double best = 60;
      for (final a in avatars) {
        final p = rig.camera.worldToScreen(a.headWorld, viewSize);
        if (p == null) continue;
        final d = (p - pos).distance;
        if (d < best) {
          best = d;
          picked = a;
          pickMethod = 'screen distance';
        }
      }
    }
    if (picked != null) {
      _log('tap -> ${picked.label} ($pickMethod)');
      rig.focusOn(picked);
    } else {
      final ground = scene.raycast(
        ray,
        where: (n) => n.name.startsWith('floor') || n.name == 'ground',
      );
      _log('tap -> ${ground?.node.name ?? 'nothing'}');
    }
    setState(() {});
  }

  // ---- input --------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails d) {
    _lastScale = 1;
    _lastRotation = 0;
    _pointers = d.pointerCount;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    _pointers = d.pointerCount;
    if (d.pointerCount >= 2) {
      rig.zoom(d.scale / _lastScale);
      rig.rotate(d.rotation - _lastRotation);
      rig.tilt(d.focalPointDelta.dy * 0.004);
      _lastScale = d.scale;
      _lastRotation = d.rotation;
      lastInput = '2-finger (pinch/twist/tilt)';
    } else if (d.pointerCount == 1) {
      rig.drag(d.focalPointDelta.dx, d.focalPointDelta.dy, viewSize.height);
      lastInput = '1-finger drag';
    } else {
      // Trackpad pan/zoom (pointerCount 0 on desktop).
      if (d.scale != _lastScale) {
        rig.zoom(d.scale / _lastScale);
        _lastScale = d.scale;
        lastInput = 'trackpad pinch';
      } else {
        rig.drag(d.focalPointDelta.dx, d.focalPointDelta.dy, viewSize.height);
        lastInput = 'trackpad pan';
      }
      if (d.rotation != _lastRotation) {
        rig.rotate(d.rotation - _lastRotation);
        _lastRotation = d.rotation;
      }
    }
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        rig.tilt(e.scrollDelta.dy * 0.002);
        lastInput = 'shift+wheel tilt';
      } else {
        rig.zoom(math.pow(1.0015, -e.scrollDelta.dy).toDouble());
        lastInput = 'wheel zoom';
      }
    }
  }

  Offset? _secondaryLast;
  void _onPointerDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse &&
        e.buttons & kSecondaryMouseButton != 0) {
      _secondaryLast = e.position;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    final last = _secondaryLast;
    if (last != null && e.buttons & kSecondaryMouseButton != 0) {
      rig.rotate(-(e.position.dx - last.dx) * 0.008);
      rig.tilt((e.position.dy - last.dy) * 0.004);
      _secondaryLast = e.position;
      lastInput = 'right-drag rotate';
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    const step = 30.0;
    if (k == LogicalKeyboardKey.keyQ) {
      rig.rotate(-0.08);
    } else if (k == LogicalKeyboardKey.keyE) {
      rig.rotate(0.08);
    } else if (k == LogicalKeyboardKey.keyW ||
        k == LogicalKeyboardKey.arrowUp) {
      rig.drag(0, step, viewSize.height);
    } else if (k == LogicalKeyboardKey.keyS ||
        k == LogicalKeyboardKey.arrowDown) {
      rig.drag(0, -step, viewSize.height);
    } else if (k == LogicalKeyboardKey.keyA ||
        k == LogicalKeyboardKey.arrowLeft) {
      rig.drag(step, 0, viewSize.height);
    } else if (k == LogicalKeyboardKey.keyD ||
        k == LogicalKeyboardKey.arrowRight) {
      rig.drag(-step, 0, viewSize.height);
    } else if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.add) {
      rig.zoom(1.1);
    } else if (k == LogicalKeyboardKey.minus) {
      rig.zoom(1 / 1.1);
    } else if (k == LogicalKeyboardKey.escape) {
      rig.backToQuarter();
    } else if (k == LogicalKeyboardKey.tab && avatars.isNotEmpty) {
      final i = rig.subject == null ? 0 : avatars.indexOf(rig.subject!) + 1;
      rig.focusOn(avatars[i % avatars.length]);
    } else {
      return KeyEventResult.ignored;
    }
    lastInput = 'key ${k.keyLabel}';
    return KeyEventResult.handled;
  }

  // ---- bench --------------------------------------------------------------

  Future<void> _runBench() async {
    // Wait for loads, settle, then sample the quarter view, a slow orbit,
    // and a focus on the first avatar.
    while (loading || avatars.length < avatarTarget) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final duringLoad = stats.window();
    final result = <String, Object>{
      'textureCap': textureCap,
      'duringLoad': duringLoad,
      'platform': '${defaultTargetPlatform.name}${kIsWeb ? '/web' : ''}',
      'mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'avatars': avatars.length,
      'shadows': kShadows,
      'freeze': kFreeze,
      'pixelRatio': kPixelRatio > 0 ? kPixelRatio : devicePixelRatio,
      'antiAliasing': scene.effectiveAntiAliasingMode.name,
      'view': '${viewSize.width.round()}x${viewSize.height.round()}',
      'loads': [for (final a in avatars) a.loadMilliseconds],
    };
    await Future<void>.delayed(const Duration(seconds: 3));
    Future<Map<String, num>> sample(
      String name,
      Duration d,
      void Function(double t) drive,
    ) async {
      stats.resetWindow();
      final sw = Stopwatch()..start();
      while (sw.elapsed < d) {
        drive(sw.elapsedMilliseconds / d.inMilliseconds);
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      final s = stats.window();
      _log('bench $name: ${jsonEncode(s)}');
      return s;
    }

    result['quarter'] = await sample(
      'quarter',
      const Duration(seconds: 6),
      (_) {},
    );
    result['orbit'] = await sample(
      'orbit',
      const Duration(seconds: 6),
      (_) => rig.rotate(0.01),
    );
    if (avatars.isNotEmpty) {
      rig.focusOn(avatars.first);
      await Future<void>.delayed(const Duration(seconds: 1));
      result['focus'] = await sample(
        'focus',
        const Duration(seconds: 6),
        (_) {},
      );
      rig.backToQuarter();
    }
    debugPrint('BENCH ${jsonEncode(result)}');
    writeBenchResult(jsonEncode(result));
    _log('bench done');
  }

  /// Scripted camera/pose steps for screenshots (TOUR=true). Each step holds
  /// for 5 s; the step name is logged so captures can be matched.
  Future<void> _runTour() async {
    while (loading || avatars.length < avatarTarget) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    Future<void> step(String name, void Function() action) async {
      setState(action);
      _log('tour: $name');
      await Future<void>.delayed(const Duration(seconds: 5));
    }

    await step('01 quarter home', rig.resetHome);
    await step('02 rotate 90', () => rig.rotate(math.pi / 2));
    await step('03 zoom in + tilt', () {
      rig.zoom(2.2);
      rig.tilt(-0.3);
    });
    await step('04 focus avatar0', () => rig.focusOn(avatars[0]));
    await step('05 talk', () => avatars[0].talking = true);
    await step('06 orbit in focus', () => rig.rotate(0.9));
    if (avatars.length > 2) {
      await step('07 focus avatar2', () => rig.focusOn(avatars[2]));
    }
    await step('08 avatar0 sleep', () {
      avatars[0].talking = false;
      _setActivity(avatars[0], AvatarActivity.lightSleep);
    });
    await step('08b sleeper from above', rig.backToQuarter);
    await step('08c zoom on bed', () => rig.zoom(3));
    await step(
      '09 avatar0 stand',
      () => _setActivity(avatars[0], AvatarActivity.idle),
    );
    await step('10 back to quarter', rig.resetHome);
    _log('tour done');
  }

  // ---- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return Scaffold(body: Center(child: Text(status)));
    }
    final subject = rig.subject;
    return Scaffold(
      backgroundColor: const Color(0xFF1B2330),
      body: LayoutBuilder(
        builder: (context, constraints) {
          viewSize = constraints.biggest;
          devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
          return Focus(
            focusNode: keyFocus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerSignal: _onPointerSignal,
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: (_) => _secondaryLast = null,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onTapUp: (d) => _tap(d.localPosition),
                      onDoubleTap: () {
                        rig.mode == CameraMode.focus
                            ? rig.backToQuarter()
                            : rig.resetHome();
                        lastInput = 'double tap';
                      },
                      child: SceneView(
                        scene,
                        camera: rig.camera,
                        onTick: _onTick,
                      ),
                    ),
                  ),
                ),
                ..._labels(),
                Positioned(left: 8, top: 8, child: _hud()),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: SafeArea(child: _controls(subject)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Flutter widgets placed over the 3D view by projecting the head.
  List<Widget> _labels() {
    final out = <Widget>[];
    for (final a in avatars) {
      final head = a.headWorld + vm.Vector3(0, 0.28, 0);
      final p = rig.camera.worldToScreen(head, viewSize);
      if (p == null ||
          p.dx < 0 ||
          p.dy < 0 ||
          p.dx > viewSize.width ||
          p.dy > viewSize.height) {
        continue;
      }
      final focused = rig.subject == a;
      final text = focused && a.talking
          ? 'こんにちは、${a.doc.name} です'
          : '${a.doc.name} · ${a.activity.name}';
      out.add(
        Positioned(
          left: p.dx - 90,
          top: p.dy - (focused ? 40 : 22),
          width: 180,
          child: IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: focused ? Colors.white : Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: focused ? 13 : 11,
                    color: focused ? Colors.black87 : Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return out;
  }

  Widget _hud() {
    final s = stats.last;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${defaultTargetPlatform.name}${kIsWeb ? '/web' : ''} '
                '${kReleaseMode
                    ? 'release'
                    : kProfileMode
                    ? 'profile'
                    : 'debug'}'
                ' · $status · shadows $kShadows',
              ),
              Text(
                'fps ${s['fps']?.toStringAsFixed(1) ?? '-'}  '
                'p50 ${s['p50ms']?.toStringAsFixed(1) ?? '-'}ms  '
                'p95 ${s['p95ms']?.toStringAsFixed(1) ?? '-'}ms',
              ),
              Text(
                'camera ${rig.mode.name}'
                '${rig.transitioning ? ' (moving)' : ''} · '
                'yaw ${(rig.yaw * vm.radians2Degrees).round() % 360}° · '
                'pointers $_pointers',
              ),
              Text('input: $lastInput · pick: $pickMethod'),
              for (final l in log) Text(l),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(VrmAvatar? subject) {
    final buttons = <Widget>[
      FilledButton.tonal(
        onPressed: loading || avatarTarget <= 1
            ? null
            : () {
                avatarTarget = math.max(1, avatarTarget - 1);
                _syncAvatars();
              },
        child: const Text('−1'),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '$avatarTarget体',
          style: const TextStyle(color: Colors.white),
        ),
      ),
      FilledButton.tonal(
        onPressed: loading
            ? null
            : () {
                avatarTarget += 1;
                _syncAvatars();
              },
        child: const Text('+1'),
      ),
      FilledButton.tonal(
        onPressed: loading
            ? null
            : () {
                avatarTarget += 5;
                _syncAvatars();
              },
        child: const Text('+5'),
      ),
      if (subject != null) ...[
        for (final (label, act) in [
          ('立つ', AvatarActivity.idle),
          ('座る', AvatarActivity.rest),
          ('寝る', AvatarActivity.lightSleep),
        ])
          FilledButton(
            onPressed: () => setState(() => _setActivity(subject, act)),
            child: Text(label),
          ),
        FilledButton(
          onPressed: () => setState(() => subject.talking = !subject.talking),
          child: Text(subject.talking ? '黙る' : '話す'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
          onPressed: () => setState(rig.backToQuarter),
          child: const Text('全体へ'),
        ),
      ] else
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
          onPressed: () => setState(rig.resetHome),
          child: const Text('ホーム'),
        ),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: buttons,
    );
  }

  /// Moves the avatar to the nearest free spot for [act].
  void _setActivity(VrmAvatar a, AvatarActivity act) {
    bool matches(Spot s) => act == AvatarActivity.lightSleep
        ? (s.activity == AvatarActivity.lightSleep ||
              s.activity == AvatarActivity.deepSleep)
        : s.activity == act;
    final taken = {
      for (final o in avatars)
        if (o != a)
          '${o.position.x.toStringAsFixed(2)},'
              '${o.position.z.toStringAsFixed(2)}',
    };
    Spot? best;
    var bestD = double.infinity;
    for (final s in garden.spots.where(matches)) {
      final key =
          '${s.position.x.toStringAsFixed(2)},${s.position.z.toStringAsFixed(2)}';
      if (taken.contains(key)) continue;
      final d = (s.position - a.position).length;
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    if (best == null) {
      _log('no free spot for ${act.name}');
      return;
    }
    a
      ..activity = best.activity
      ..position = best.position.clone()
      ..yaw = best.yaw
      ..seatHeight = best.seatHeight;
    rig.focusOn(a);
    _log('${a.label} -> ${best.name}');
  }
}

/// Frame-interval statistics from SceneView ticks.
class FrameStats {
  final List<double> _window = [];
  final List<double> _recent = [];
  Map<String, num> last = {};
  double _sinceRefresh = 0;

  bool get shouldRefresh {
    if (_sinceRefresh >= 0.5) {
      _sinceRefresh = 0;
      last = _summary(_recent);
      _recent.clear();
      return true;
    }
    return false;
  }

  void add(double dt) {
    if (dt <= 0) return;
    _window.add(dt);
    _recent.add(dt);
    _sinceRefresh += dt;
  }

  void resetWindow() => _window.clear();

  Map<String, num> window() => _summary(_window);

  static Map<String, num> _summary(List<double> xs) {
    if (xs.isEmpty) return {};
    final sorted = [...xs]..sort();
    double q(double p) => sorted[((sorted.length - 1) * p).round()] * 1000;
    final total = xs.fold<double>(0, (a, b) => a + b);
    return {
      'frames': xs.length,
      'fps': xs.length / total,
      'p50ms': q(0.5),
      'p95ms': q(0.95),
      'maxms': sorted.last * 1000,
    };
  }
}
