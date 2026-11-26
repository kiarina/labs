import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_scene/scene.dart' hide Material;
import 'package:flutter_vrm/flutter_vrm.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:webview_flutter/webview_flutter.dart';

import 'agent.dart';
import 'bridge.dart';
import 'motion.dart';

const _instructions = '''
You are a small character living in a 3D window. Your body is a VRM avatar
moved by a text-to-motion model (ARDY): you cannot pose bones yourself; you
describe the motion and the model performs it.

- To change what your body does, call `move` with one short, well-formed
  English sentence in the style "A person ...", e.g. "A person waves with the
  right hand.", "A person walks forward slowly.", "A person jumps twice.".
  Typo-free English only; describe the body, not emotions alone.
- The motion keeps going (the model continues it) until you call `move`
  again. To calm down, use "A person stands still." or "A person stands idle,
  shifting weight.".
- Move when the user asks you to, and also on your own when it fits what you
  say (a greeting, joy, thinking). One `move` per beat; a sequence is several
  calls with your words in between is not possible, so pick the one motion
  that fits best for now.
- Reply to the user in Japanese, in one or two short sentences.
''';

final _tools = <Map<String, dynamic>>[
  {
    'name': 'move',
    'description':
        'Change the motion of your body. The text-to-motion model starts it '
        'about one second from now and continues it until the next move.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'motion': {
          'type': 'string',
          'description':
              'One well-formed English sentence, e.g. "A person waves with '
              'the right hand."',
        },
      },
      'required': ['motion'],
      'additionalProperties': false,
    },
  },
];

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ARDY VRM agent',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
{
  final scene = Scene();
  final camera = PerspectiveCamera(
    fovRadiansY: 30 * vm.degrees2Radians,
    fovNear: 0.05,
    fovFar: 100,
  );
  final _sceneKey = GlobalKey();
  VrmAvatar? avatar;
  LoopbackServer? server;
  ArdyBridge? bridge;
  MotionDirector? director;
  Agent? agent;
  HttpServer? control;
  final log = <String>[];
  String status = 'starting';
  String progress = '';
  final _input = TextEditingController();
  final _motionInput = TextEditingController();
  vm.Vector3 _focus = vm.Vector3(0, 1, 0);
  double yaw = 0;

  /// Frame times for the fps line.
  final _frameTimes = <double>[];

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _log(String line) {
    debugPrint(line);
    setState(() {
      log.add(line);
      if (log.length > 200) log.removeAt(0);
    });
  }

  Future<void> _init() async {
    try {
      await _startControl();
      await _initScene();
    } catch (e, st) {
      _log('init failed: $e\n$st');
      setState(() => status = 'init failed: $e');
    }
  }

  Future<void> _initScene() async {
    _log('scene: initializing');
    await Scene.initializeStaticResources();
    scene.directionalLight = DirectionalLight(
      direction: vm.Vector3(-0.3, -1, -0.5)..normalize(),
      intensity: 3,
      castsShadow: true,
    );
    scene.add(
      Node(
        name: 'floor',
        mesh: Mesh(
          CuboidGeometry(vm.Vector3(30, 0.02, 30)),
          PhysicallyBasedMaterial()
            ..baseColorFactor = vm.Vector4(0.55, 0.58, 0.6, 1)
            ..roughnessFactor = 0.9
            ..metallicFactor = 0,
        ),
        localTransform: vm.Matrix4.translation(vm.Vector3(0, -0.01, 0)),
      ),
    );
    // Grid posts so walking is visible against the floor.
    for (var x = -6; x <= 6; x += 2) {
      for (var z = -6; z <= 6; z += 2) {
        scene.add(
          Node(
            mesh: Mesh(
              CuboidGeometry(vm.Vector3(0.06, 0.03, 0.06)),
              UnlitMaterial()..baseColorFactor = vm.Vector4(0.2, 0.25, 0.3, 1),
            ),
            localTransform: vm.Matrix4.translation(
              vm.Vector3(x.toDouble(), 0.0, z.toDouble()),
            ),
          ),
        );
      }
    }

    final vrmPath = Platform.environment['VRM_PATH'] ?? '';
    if (vrmPath.isEmpty || !File(vrmPath).existsSync()) {
      setState(() => status = 'VRM_PATH is not set or missing: $vrmPath');
      return;
    }
    final a = await VrmAvatar.fromBytes(await File(vrmPath).readAsBytes());
    scene.add(a.root);
    a.update(0);
    setState(() => avatar = a);
    _log('vrm: ${a.meta.name}');

    final webDir = Platform.environment['WEB_DIR'] ?? '';
    final s = LoopbackServer(webDir);
    await s.start();
    server = s;
    final b = ArdyBridge(s.origin.resolve('index.html'))..create();
    final d = MotionDirector(b);
    bridge = b;
    director = d;
    d.addListener(() => setState(() {}));
    b.events.listen((e) => _onBridgeEvent(e, a));
    setState(() => status = 'page loading');
    if ((Platform.environment['AGENT'] ?? '1') != '0') unawaited(_startAgent());
  }

  final _loadStarted = DateTime.now();

  Future<void> _onBridgeEvent(Map<String, dynamic> e, VrmAvatar a) async {
    director?.onEvent(e);
    switch (e['type']) {
      case 'page':
        _log('page: webgpu=${e['webgpu']} secure=${e['secure']}');
        _log('ua: ${e['userAgent']}');
      case 'workerReady':
        final hips = a.humanoid.restModelPosition(VrmHumanBone.hips)!;
        final toes = [
          a.humanoid.restModelPosition(VrmHumanBone.leftToes),
          a.humanoid.restModelPosition(VrmHumanBone.leftFoot),
        ].whereType<vm.Vector3>().map((v) => v.y);
        final ground = toes.isEmpty ? 0.0 : toes.reduce(math.min);
        final present = a.humanoid.bones.map((b) => b.name).toList();
        _log('worker ready; hips height ${(hips.y - ground).toStringAsFixed(3)}');
        await bridge!.command({
          'type': 'load',
          'presentBones': present,
          'hipsHeight': hips.y - ground,
        });
        setState(() => status = 'loading model');
      case 'webGpu':
        _log('webgpu: shader-f16=${e['shaderF16']} → ${e['variant']}');
      case 'progress':
        setState(
          () => progress =
              '${e['stage']} ${e['completed']}/${e['total']} ${e['message'] ?? ''}',
        );
      case 'loaded':
        _log(
          'model loaded: ${e['modelId']} ${e['variant']} in ${e['loadMs']} ms '
          '(${DateTime.now().difference(_loadStarted).inMilliseconds} ms since launch)',
        );
        setState(() {
          status = 'ready';
          progress = '';
        });
        director!.setPrompt(
          Platform.environment['FIRST_MOTION'] ?? 'A person stands idle.',
        );
      case 'complete':
        final t = e['timingsMs'] as Map?;
        _log(
          '${e['mode']}: ${e['generatedFrameCount']} frames in ${e['wallMs']} ms '
          '(text ${t?['text']?.round()}, denoise ${t?['denoising']?.round()}, '
          'decode ${t?['decoding']?.round()})',
        );
      case 'error':
        _log('error: ${jsonEncode(e['error'])}');
        setState(() => status = 'error');
    }
  }

  Future<void> _startAgent() async {
    final g = Agent(
      instructions: _instructions,
      tools: _tools,
      onTool: (name, args) async {
        if (name != 'move') return ToolOutcome('unknown tool', ok: false);
        final motion = (args['motion'] as String? ?? '').trim();
        if (motion.isEmpty) return ToolOutcome('motion is empty', ok: false);
        final d = director;
        if (d == null || !d.loaded) {
          return ToolOutcome('the body is not ready yet', ok: false);
        }
        d.setPrompt(motion);
        _log('agent move: $motion');
        return ToolOutcome('ok: your body will start "$motion" in about 1 s');
      },
    );
    g.addListener(() => setState(() {}));
    try {
      await g.start(
        model: Platform.environment['MODEL'] ?? 'gpt-6.1-terra',
        // Picking a motion sentence needs little reasoning; keep turns short.
        effort: switch (Platform.environment['EFFORT']) {
          null || '' => 'low',
          final e => e,
        },
      );
      agent = g;
      _log('agent: ${g.model}');
    } catch (e) {
      _log('agent failed: $e');
    }
  }

  /// A small local HTTP API to drive and inspect the app (for the lab).
  Future<void> _startControl() async {
    final port = int.tryParse(Platform.environment['CONTROL_PORT'] ?? '') ?? 0;
    if (port == 0) return;
    final c = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    control = c;
    _log('control: http://127.0.0.1:$port/');
    c.listen((req) async {
      final res = req.response;
      try {
        final body = await utf8.decoder.bind(req).join();
        switch (req.uri.path) {
          case '/status':
            res.headers.contentType = ContentType.json;
            res.write(jsonEncode(_statusJson()));
          case '/motion':
            director?.setPrompt(body);
            res.write('ok');
          case '/chat':
            await agent?.send(body, role: 'user');
            res.write('ok');
          case '/screenshot':
            final png = await _screenshot();
            res.headers.contentType = ContentType('image', 'png');
            res.add(png);
          default:
            res.statusCode = 404;
        }
      } catch (e) {
        res.statusCode = 500;
        res.write('$e');
      }
      await res.close();
    });
  }

  Map<String, dynamic> _statusJson() {
    final d = director;
    final fps = _frameTimes.isEmpty
        ? 0
        : _frameTimes.length / _frameTimes.reduce((a, b) => a + b);
    return {
      'status': status,
      'progress': progress,
      'fps': fps.toStringAsFixed(1),
      'prompt': d?.prompt,
      'frameCount': d?.frameCount,
      'playhead': d?.playhead.toStringAsFixed(1),
      'generating': d?.generating,
      'stalls': d?.stalls,
      'stallSeconds': d?.stallSeconds.toStringAsFixed(2),
      'records': [for (final r in d?.records ?? <GenerationRecord>[]) r.toJson()],
      'agent': {
        'model': agent?.model,
        'running': agent?.running,
        'turns': [
          for (final t in agent?.timings ?? <Map<String, dynamic>>[])
            {
              'status': t['status'],
              'totalMs': (t['ended'] as DateTime)
                  .difference(t['started'] as DateTime)
                  .inMilliseconds,
              'firstToolMs': (t['first_tool'] as DateTime?)
                  ?.difference(t['started'] as DateTime)
                  .inMilliseconds,
              'tools': t['tools'],
            },
        ],
        'entries': [
          for (final e in agent?.entries ?? <ChatEntry>[])
            {'role': e.role, 'tool': e.tool, 'text': e.text},
        ],
      },
      'log': log.length > 40 ? log.sublist(log.length - 40) : log,
    };
  }

  Future<List<int>> _screenshot() async {
    final boundary =
        _sceneKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // The scene repaints every frame; read it right after a frame is drawn,
    // or debug builds assert that the boundary still needs painting.
    ui.Image? image;
    for (var attempt = 0; image == null; attempt++) {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      try {
        image = await boundary.toImage(pixelRatio: 1);
      } on AssertionError {
        if (attempt >= 10) rethrow;
      }
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  void _onTick(Duration elapsed, double frameDt) {
    final dt = frameDt.clamp(0.0, 0.1);
    if (dt > 0) {
      _frameTimes.add(dt);
      if (_frameTimes.length > 120) _frameTimes.removeAt(0);
    }
    final a = avatar;
    if (a == null) return;
    director?.update(dt, a);
    a.mtoonLighting.fromScene(scene);
    a.update(dt, camera: camera);
    final hips = a.humanoid.worldPosition(VrmHumanBone.hips);
    if (hips != null) {
      final target = vm.Vector3(hips.x, 0.9, hips.z);
      _focus += (target - _focus) * math.min(1.0, dt * 3);
    }
    final eye = _focus + vm.Vector3(math.sin(yaw), 0.25, -math.cos(yaw)) * 4.2;
    camera
      ..position = eye
      ..target = _focus;
    setState(() {});
  }

  void _sendChat() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    agent?.send(text, role: 'user');
  }

  @override
  Widget build(BuildContext context) {
    final d = director;
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onHorizontalDragUpdate: (u) => yaw -= u.delta.dx * 0.01,
                    child: RepaintBoundary(
                      key: _sceneKey,
                      child: SceneView(scene, camera: camera, onTick: _onTick),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  top: 12,
                  right: 12,
                  child: Text(
                    '$status  $progress\n'
                    '${d == null ? '' : 'motion: ${d.prompt ?? '-'}   frame ${d.playhead.toStringAsFixed(0)}/${d.frameCount}'
                              '${d.generating ? '  generating' : ''}   stalls ${d.stalls} (${d.stallSeconds.toStringAsFixed(1)} s)'}',
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 12,
                      shadows: [Shadow(blurRadius: 3)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 380,
            child: Column(
              children: [
                // The WebView runs ARDY; it has to be in the tree.
                SizedBox(
                  height: 90,
                  child: bridge == null
                      ? const SizedBox()
                      : WebViewWidget(controller: bridge!.controller),
                ),
                Expanded(child: _chatList()),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    controller: _motionInput,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'motion (direct, English)',
                    ),
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) director?.setPrompt(v);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: TextField(
                    controller: _input,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'chat with the agent'
                          '${agent?.model == null ? '' : ' (${agent!.model})'}',
                    ),
                    onSubmitted: (_) => _sendChat(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatList() {
    final entries = agent?.entries ?? const <ChatEntry>[];
    return ListView(
      reverse: true,
      padding: const EdgeInsets.all(8),
      children: [
        for (final e in entries.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              e.role == 'tool' ? '⚙ ${e.tool}: ${e.text}' : '${e.role}: ${e.text}',
              style: TextStyle(
                fontSize: 12,
                color: switch (e.role) {
                  'user' => Colors.tealAccent,
                  'tool' => Colors.amber,
                  'error' => Colors.redAccent,
                  _ => null,
                },
              ),
            ),
          ),
        for (final l in log.reversed.take(12))
          Text(l, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  @override
  void dispose() {
    agent?.dispose();
    server?.close();
    control?.close(force: true);
    super.dispose();
  }
}
