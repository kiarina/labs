import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'canvas/behaviors.dart';
import 'canvas/canvas_model.dart';
import 'canvas/canvas_view.dart';
import 'canvas/scenes.dart';
import 'canvas/sound.dart';
import 'canvas/speech.dart';
import 'canvas/web_host.dart';
import 'control_server.dart';
import 'demo_scene.dart';
import 'media.dart';
import 'self_test.dart';
import 'spirit.dart';
import 'spirit_tools.dart';

/// Waits for the next frame, at most [limit]: with the window minimized or
/// hidden, Flutter draws no frames, and a plain wait never returns.
Future<void> nextFrame({Duration limit = const Duration(milliseconds: 500)}) {
  WidgetsBinding.instance.scheduleFrame();
  return WidgetsBinding.instance.endOfFrame.timeout(limit, onTimeout: () {});
}

void main() {
  runApp(const SpiritCanvasApp());
}

class SpiritCanvasApp extends StatelessWidget {
  const SpiritCanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spirit canvas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C8CFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final canvas = CanvasController();
  final sounds = SoundBoard();
  late final SpeechPlayer speech = SpeechPlayer(canvas)
    ..onSpoken = (id, text) {
      canvas.emit(CanvasEvent('spoken', id, {'text': text}));
    }
    ..onProblem = (p) {
      behaviors.notice('<canvas_notice from="speech" problem="${_attr(p)}"/>');
    };
  late final CanvasBehaviors behaviors = CanvasBehaviors(
    canvas,
    wake: (lines) => _send(lines, role: 'event'),
    sounds: sounds,
    speech: speech,
  );
  final scenes = SceneStore(
    builtinDir: env('SCENES_DIR'),
    savedDir: env('SAVED_SCENES_DIR'),
  );
  final canvasKey = GlobalKey();
  final canvasFrontKey = GlobalKey();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final Spirit spirit;

  /// `chat` or `canvas`.
  String mode = env('START_MODE', 'canvas');

  /// The spirit's latest words, shown over the canvas while they stream in
  /// and for a while after ([_captionHold]); a touch on the canvas hides them.
  ChatEntry? caption;
  bool captionShown = false;
  Timer? _captionTimer;

  void _showCaption(ChatEntry e) {
    _captionTimer?.cancel();
    setState(() {
      caption = e;
      captionShown = true;
    });
    if (e.done) {
      // About 4 s plus the time to read it (Japanese: ~8 characters a second).
      final hold = Duration(
        milliseconds: 4000 + (e.text.length * 1000 / 8).round(),
      );
      _captionTimer = Timer(hold, hideCaption);
    }
  }

  void hideCaption() {
    _captionTimer?.cancel();
    if (mounted && captionShown) setState(() => captionShown = false);
  }

  final _pendingEvents = <CanvasEvent>[];
  Timer? _eventTimer;
  ControlServer? _control;

  @override
  void initState() {
    super.initState();
    spirit = Spirit(
      instructions: kSpiritInstructions,
      tools: kCanvasTools,
      onTool: runTool,
    )..onSpiritText = _showCaption;
    spirit.addListener(_spiritChanged);
    canvas.onEvent = _onCanvasEvent;
    canvas.onResize = _onResize;
    _start();
  }

  Future<void> _start() async {
    await WebHost.instance.start();
    WebHost.instance.onMessage = _onWebMessage;
    final model = env('MODEL');
    final effort = env('EFFORT');
    try {
      await spirit.start(
        model: model.isEmpty ? null : model,
        effort: effort.isEmpty ? null : effort,
      );
    } catch (e) {
      // No Codex here (iOS, Android): the canvas still works, driven
      // through the control port.
      setState(() => spirit.status = 'no spirit: $e');
    }
    final port = int.tryParse(env('CONTROL_PORT')) ?? 0;
    if (port > 0) _control = await ControlServer.start(port, this);
    if (env('SELF_TEST') == '1') unawaited(runSelfTest(this));
  }

  @override
  void dispose() {
    _control?.close();
    behaviors.dispose();
    speech.dispose();
    sounds.dispose();
    spirit.dispose();
    super.dispose();
  }

  void _spiritChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Sends lines to the spirit with the mode tag and the notices that waited
  /// for the next message.
  Future<void> _send(List<String> lines, {required String role}) {
    final text = [
      '<ui mode="$mode" canvas="${canvas.size.width.round()}x${canvas.size.height.round()}" '
          'orientation="${canvas.orientation}"${canvas.design != null ? ' design="fixed, scaled to the screen"' : ''}/>',
      ...behaviors.takeNotices(),
      ...lines,
    ].join('\n');
    return spirit.send(text, role: role, mode: mode);
  }

  Future<void> sendUser(String text) async {
    if (text.trim().isEmpty) return;
    await _send([text], role: 'user');
  }

  Size? _resizeFrom;
  Timer? _resizeTimer;

  /// The canvas changed size: scripts hear at once; the spirit, once the
  /// size settles (a window being dragged fires many), now if the
  /// orientation flipped or the area changed by a quarter or more, else
  /// with the next message.
  void _onResize(Size from, Size to, {required bool byScreen}) {
    behaviors.resized(to);
    // A design the spirit set (or a scene it loaded) is its own doing.
    if (!byScreen) return;
    _resizeFrom ??= from;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 700), () {
      final a = _resizeFrom!;
      final b = canvas.size;
      _resizeFrom = null;
      if (a == b) return;
      final flipped = (a.width >= a.height) != (b.width >= b.height);
      final ratio = (b.width * b.height) / math.max(1, a.width * a.height);
      final big = ratio > 1.25 || ratio < 0.75;
      final line =
          '<canvas_event event="resize" id="canvas" value="${b.width.round()}x${b.height.round()}" '
          'from="${a.width.round()}x${a.height.round()}" orientation="${canvas.orientation}"/>';
      if (canvas.elements.isEmpty) return;
      if (flipped || big) {
        _send([line], role: 'event');
      } else {
        behaviors.notice(line);
      }
    });
  }

  /// A message from a `web` element's page (`sg.emit`, `sg.setState`,
  /// errors).
  void _onWebMessage(String id, Map<String, dynamic> m) {
    switch (m['type']) {
      case 'event':
        _onCanvasEvent(
          CanvasEvent('web', id, {'name': m['name'], 'data': m['data']}),
          wake: m['wake'] as bool?,
          laterReason: 'the page asked to tell you later',
        );
      case 'error':
        behaviors.notice(
          '<canvas_notice from="web:${_attr(id)}" error="${_attr('${m['text']}')}"/>',
        );
      case 'log':
        debugPrint('[web:$id] ${m['text']}');
    }
  }

  void _onCanvasEvent(CanvasEvent e, {bool? wake, String? laterReason}) {
    hideCaption();
    // The element's own actions and the scripts' handlers run here, at once.
    var decided = behaviors.handleEvent(e);
    // A line said to its end is news, not a call: told later unless
    // something asked otherwise.
    if (e.kind == 'spoken' && decided == 'now' && wake == null) {
      decided = 'later';
    }
    switch (wake == null ? decided : (wake ? 'now' : 'later')) {
      case 'none':
        return;
      case 'later':
        behaviors.notice(
          _eventLine(
            e,
            handled: true,
            reason: wake == false ? laterReason : null,
          ),
        );
        return;
    }
    _pendingEvents.add(e);
    // Events that come together (a choice, then a submit) go as one message.
    _eventTimer?.cancel();
    _eventTimer = Timer(const Duration(milliseconds: 250), _flushEvents);
  }

  void _flushEvents() {
    if (_pendingEvents.isEmpty) return;
    final lines = [for (final e in _pendingEvents) _eventLine(e)];
    _pendingEvents.clear();
    _send(lines, role: 'event');
  }

  String _eventLine(CanvasEvent e, {bool handled = false, String? reason}) =>
      '<canvas_event event="${e.kind}" id="${_attr(e.id)}"'
      '${e.value != null ? ' value="${_attr(e.value is String ? e.value as String : jsonEncode(e.value))}"' : ''}'
      '${handled ? ' handled="${reason ?? 'on the canvas'}" at="${e.at.toIso8601String().substring(11, 19)}"' : ''}/>';

  String _attr(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;');

  /// Runs one canvas tool for the spirit.
  Future<ToolOutcome> runTool(String name, Map<String, dynamic> a) async {
    switch (name) {
      case 'canvas_view':
        final elements = canvas.describe(
          abbreviate: env('ABBREVIATE_VIEW', '1') == '1',
        );
        final text = jsonEncode({
          'mode': mode,
          'canvas': {
            'width': canvas.size.width.round(),
            'height': canvas.size.height.round(),
            'orientation': canvas.orientation,
            if (canvas.design != null) ...{
              'design': true,
              'screen': {
                'width': canvas.screen.width.round(),
                'height': canvas.screen.height.round(),
              },
            },
            'background': canvas.background,
          },
          'elements': elements,
          ...behaviors.describe(),
          if (WebHost.instance.pages.isNotEmpty)
            'web': {
              for (final id in WebHost.instance.pages.keys)
                id: {
                  'state': WebHost.instance.states[id],
                  // The picture does not show web views: their text instead.
                  'text': await WebHost.instance.eval(
                    id,
                    "document.body ? document.body.innerText.slice(0, 800) : ''",
                  ),
                },
            },
        });
        final images = <String>[];
        var note = '';
        if (a['image'] as bool? ?? true) {
          // Let a just-changed canvas draw first.
          await nextFrame();
          final shot = await captureCanvasWithWeb(
            canvasKey,
            canvas,
            frontKey: canvasFrontKey,
          );
          if (shot.png != null) images.add(shot.png!);
          if (shot.missing.isNotEmpty) {
            note =
                '\n(web elements whose picture is missing or old: ${jsonEncode(shot.missing)})';
          }
          // Android draws a web view's last frame: with the app in the
          // background, page changes since then are not in the picture.
          if (Platform.isAndroid &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed &&
              canvas.elements.values.any((e) => e.type == 'web')) {
            note += '\n(the app is in the background: web pages in the picture may be out of date; read their state and text instead)';
          }
        }
        return ToolOutcome('$text$note', images: images);
      case 'canvas_put':
        final items = [
          for (final e in (a['elements'] as List? ?? const []))
            if (e is Map) e.cast<String, dynamic>(),
        ];
        final problems = canvas.put(items);
        return ToolOutcome(
          problems.isEmpty
              ? 'ok: put ${items.length}'
              : 'put ${items.length - problems.length}; problems: ${problems.join('; ')}',
          ok: problems.length < items.length || items.isEmpty,
        );
      case 'canvas_update':
        final err = canvas.update(
          a['id'] as String,
          (a['props'] as Map? ?? const {}).cast<String, dynamic>(),
          transitionMs: (a['transition_ms'] as num?)?.toDouble(),
          easing: a['easing'] as String? ?? 'ease_in_out',
        );
        return ToolOutcome(err ?? 'ok', ok: err == null);
      case 'canvas_animate':
        final err = canvas.animate(
          a['id'] as String,
          keyframes: [
            for (final k in (a['keyframes'] as List? ?? const []))
              if (k is Map) k.cast<String, dynamic>(),
          ],
          durationMs: (a['duration_ms'] as num?)?.toDouble() ?? 1000,
          repeat: (a['repeat'] as num?)?.toInt() ?? 1,
          alternate: a['alternate'] as bool? ?? false,
          easing: a['easing'] as String? ?? 'ease_in_out',
        );
        return ToolOutcome(err ?? 'ok', ok: err == null);
      case 'canvas_remove':
        final missing = canvas.remove([
          for (final id in (a['ids'] as List? ?? const [])) '$id',
        ]);
        return ToolOutcome(
          missing.isEmpty ? 'ok' : 'not found: ${missing.join(', ')}',
        );
      case 'canvas_clear':
        unawaited(sounds.stopAll());
        speech.stop();
        behaviors.reset();
        canvas.state.clear();
        canvas.clear(background: a['background'] as String?);
        final design = a['design'] as Map?;
        canvas.setDesign(
          design == null
              ? null
              : Size(
                  (design['width'] as num).toDouble(),
                  (design['height'] as num).toDouble(),
                ),
        );
        return ToolOutcome(
          'ok: the canvas is ${canvas.size.width.round()}x${canvas.size.height.round()}'
          '${canvas.design != null ? ' (fixed, scaled to the screen)' : ' (the screen)'}',
        );
      case 'canvas_state':
        final set = (a['set'] as Map? ?? const {}).cast<String, dynamic>();
        for (final k in (a['delete'] as List? ?? const [])) {
          canvas.state.remove('$k');
        }
        canvas.setState(set);
        behaviors.stateChangedBySpirit();
        return ToolOutcome(jsonEncode({'state': canvas.state}));
      case 'canvas_timeline':
        final err = behaviors.defineTimeline(
          a['id'] as String,
          [
            for (final st in (a['steps'] as List? ?? const []))
              if (st is Map) st.cast<String, dynamic>(),
          ],
          repeat: (a['repeat'] as num?)?.toInt() ?? 1,
          cycleMs: (a['cycle_ms'] as num?)?.toDouble(),
          start: a['start'] as bool? ?? true,
        );
        return ToolOutcome(err ?? 'ok', ok: err == null);
      case 'canvas_timeline_stop':
        return ToolOutcome(
          behaviors.stopTimeline(a['id'] as String)
              ? 'ok'
              : 'no timeline "${a['id']}"',
        );
      case 'canvas_script':
        final err = behaviors.loadScript(
          a['id'] as String,
          a['code'] as String,
        );
        // Let the script's first changes draw before the spirit looks.
        await nextFrame();
        return ToolOutcome(
          err == null ? 'ok: running' : 'failed: $err',
          ok: err == null,
        );
      case 'canvas_script_stop':
        return ToolOutcome(
          behaviors.stopScript(a['id'] as String)
              ? 'ok'
              : 'no script "${a['id']}"',
        );
      case 'canvas_speak':
        final problems = behaviors.runActions([
          {'do': 'speak', ...a},
        ], from: 'spirit');
        return ToolOutcome(
          problems.isEmpty ? 'ok: queued' : problems.join('; '),
          ok: problems.isEmpty,
        );
      case 'canvas_audio':
        final actions = [
          if (a['sound'] case final Map m)
            {'do': 'sound', ...m.cast<String, dynamic>()},
          if (a.containsKey('bgm'))
            {
              'do': 'bgm',
              if (a['bgm'] case final Map m) ...m.cast<String, dynamic>(),
              if ((a['bgm'] as Map?)?['stop'] == true) 'src': null,
            },
        ];
        if (actions.isEmpty) return ToolOutcome('nothing to play', ok: false);
        final problems = behaviors.runActions(actions, from: 'spirit');
        return ToolOutcome(
          problems.isEmpty ? 'ok' : problems.join('; '),
          ok: problems.isEmpty,
        );
      case 'canvas_scenes':
        return ToolOutcome(jsonEncode({'scenes': scenes.list()}));
      case 'canvas_save':
        return _saveScene(a);
      case 'canvas_load':
        return _loadScene(a);
      case 'canvas_web_eval':
        return ToolOutcome(
          await WebHost.instance.eval(a['id'] as String, a['js'] as String),
        );
      case 'canvas_media':
        return ToolOutcome(
          jsonEncode({
            ...MediaLibrary.instance.list(),
            'model_info': MediaLibrary.instance.modelInfo(),
          }),
        );
    }
    return ToolOutcome('unknown tool $name', ok: false);
  }

  ToolOutcome _saveScene(Map<String, dynamic> a) {
    final name = a['name'] as String;
    final params = <String, dynamic>{
      for (final MapEntry(:key, :value)
          in (a['params'] as Map? ?? const {}).entries)
        '$key': {
          ...(value as Map? ?? const {}).cast<String, dynamic>(),
          // A param without a default takes the value it has now.
          if (value?['default'] == null && canvas.state.containsKey(key))
            'default': canvas.state[key],
        },
    };
    final scene = {
      'name': name,
      'description': a['description'],
      'params': params,
      'background': canvas.background,
      // null: made to follow the screen's size.
      'design': switch (canvas.design) {
        final d? => {'width': d.width, 'height': d.height},
        null => null,
      },
      'elements': [for (final e in canvas.ordered) e.toJson()],
      'state': {
        for (final MapEntry(:key, :value) in canvas.state.entries)
          if (!params.containsKey(key)) key: value,
      },
      'timelines': behaviors.timelineDefs,
      'scripts': behaviors.scriptSources,
      'bgm': ?sounds.bgmState,
      'saved_at': DateTime.now().toIso8601String(),
    };
    try {
      final bytes = scenes.write(name, scene);
      return ToolOutcome(
        'ok: saved "$name" ($bytes bytes, ${canvas.elements.length} elements, '
        '${behaviors.scriptSources.length} scripts, ${behaviors.timelineDefs.length} timelines)',
      );
    } on Object catch (e) {
      return ToolOutcome('failed: $e', ok: false);
    }
  }

  Future<ToolOutcome> _loadScene(Map<String, dynamic> a) async {
    final watch = Stopwatch()..start();
    final name = a['name'] as String;
    final scene = scenes.read(name);
    if (scene == null) return ToolOutcome('no scene "$name"', ok: false);
    final values = (a['values'] as Map? ?? const {}).cast<String, dynamic>();
    final params = (scene['params'] as Map? ?? const {})
        .cast<String, dynamic>();
    final problems = <String>[
      for (final k in values.keys)
        if (!params.containsKey(k)) 'unknown param "$k"',
    ];
    behaviors.reset();
    canvas.state.clear();
    canvas.clear(background: scene['background'] as String?);
    // Scenes saved before the canvas followed the screen were made at
    // 1280x800: keep them at it, scaled to fit.
    final design = scene.containsKey('design')
        ? switch (scene['design']) {
            final Map d => Size(
              (d['width'] as num).toDouble(),
              (d['height'] as num).toDouble(),
            ),
            _ => null,
          }
        : kLegacyDesign;
    canvas.setDesign(design);
    canvas.setState({
      ...(scene['state'] as Map? ?? const {}).cast<String, dynamic>(),
      for (final MapEntry(:key, :value) in params.entries)
        if ((value as Map?)?['default'] != null) key: value!['default'],
      ...values,
    });
    behaviors.stateChangedBySpirit();
    problems.addAll(
      canvas.put([
        for (final e in (scene['elements'] as List? ?? const []))
          if (e is Map) e.cast<String, dynamic>(),
      ]),
    );
    for (final MapEntry(:key, :value)
        in (scene['timelines'] as Map? ?? const {})
            .cast<String, dynamic>()
            .entries) {
      final t = (value as Map).cast<String, dynamic>();
      final err = behaviors.defineTimeline(
        key,
        [
          for (final st in (t['steps'] as List? ?? const []))
            if (st is Map) st.cast<String, dynamic>(),
        ],
        repeat: (t['repeat'] as num?)?.toInt() ?? 1,
        cycleMs: (t['cycle_ms'] as num?)?.toDouble(),
        start: t['start'] as bool? ?? true,
      );
      if (err != null) problems.add('timeline $key: $err');
    }
    for (final MapEntry(:key, :value)
        in (scene['scripts'] as Map? ?? const {})
            .cast<String, dynamic>()
            .entries) {
      final err = behaviors.loadScript(key, '$value');
      if (err != null) problems.add('script $key: $err');
    }
    final bgm = (scene['bgm'] as Map?)?.cast<String, dynamic>();
    behaviors.runActions([
      {
        'do': 'bgm',
        'src': bgm?['src'],
        'volume': bgm?['volume'] ?? 0.5,
        'fade_ms': 800,
      },
    ], from: 'scene:$name');
    final ms = watch.elapsedMilliseconds;
    await nextFrame();
    debugPrint('[scene] loaded $name in ${ms}ms');
    return ToolOutcome(
      'ok: loaded "$name" in ${ms}ms (${canvas.elements.length} elements)'
      '${problems.isEmpty ? '' : '; problems: ${problems.join('; ')}'}',
    );
  }

  /// Saves a PNG of the canvas (for the lab's records).
  Future<String?> saveSnapshot(String name) async {
    final dir = env(
      'LOG_DIR',
      '${Directory.systemTemp.path}/spirit-canvas-logs',
    );
    await nextFrame();
    final png = (await captureCanvasWithWeb(
      canvasKey,
      canvas,
      pixelRatio: 1,
      frontKey: canvasFrontKey,
    )).png;
    if (png == null) return null;
    final f = File('$dir/$name.png');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(base64Decode(png));
    return f.path;
  }

  void setMode(String m) => setState(() => mode = m);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: Stack(
                children: [
                  // The canvas stays mounted (and drawn) in chat mode, so the
                  // spirit can still look at it and media keep their state.
                  Positioned.fill(
                    child: Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      // Any touch on the canvas hides the caption.
                      child: Listener(
                        onPointerDown: (_) => hideCaption(),
                        child: CanvasView(
                          controller: canvas,
                          boundaryKey: canvasKey,
                          frontKey: canvasFrontKey,
                        ),
                      ),
                    ),
                  ),
                  if (mode == 'canvas' &&
                      caption != null &&
                      caption!.text.isNotEmpty)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 12,
                      child: IgnorePointer(
                        ignoring: !captionShown,
                        child: AnimatedOpacity(
                          opacity: captionShown ? 1 : 0,
                          duration: const Duration(milliseconds: 300),
                          child: GestureDetector(
                            onTap: hideCaption,
                            child: _caption(caption!),
                          ),
                        ),
                      ),
                    ),
                  if (mode == 'chat')
                    Positioned.fill(
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: _history(),
                      ),
                    ),
                ],
              ),
            ),
            _inputBar(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'chat',
                icon: Icon(Icons.chat_bubble_outline),
                label: Text('チャット'),
              ),
              ButtonSegment(
                value: 'canvas',
                icon: Icon(Icons.brush_outlined),
                label: Text('キャンバス'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) => setMode(s.first),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              '${spirit.status}${spirit.model != null ? ' · ${spirit.model}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () async {
              for (final call in kDemoScene) {
                await runTool(call.$1, call.$2);
              }
            },
            child: const Text('見本'),
          ),
          if (spirit.running) ...[
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: spirit.interrupt,
            ),
          ],
        ],
      ),
    );
  }

  Widget _caption(ChatEntry e) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xCC000000),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          e.text,
          style: const TextStyle(
            fontSize: 16,
            color: Colors.white,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _history() {
    final entries = spirit.entries;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final scheme = Theme.of(context).colorScheme;
        final text = e.text.replaceFirst(RegExp(r'^<ui mode="\w+"/>\n'), '');
        switch (e.role) {
          case 'tool':
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '⚙ ${e.tool}  $text',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'Menlo',
                ),
              ),
            );
          case 'error':
            return Text('⚠ $text', style: TextStyle(color: scheme.error));
        }
        final mine = e.role == 'user' || e.role == 'event';
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 640),
            decoration: BoxDecoration(
              color: mine
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              e.role == 'event' ? '🖱 $text' : text,
              style: TextStyle(fontSize: e.role == 'event' ? 12 : 15),
            ),
          ),
        );
      },
    );
  }

  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: mode == 'canvas' ? 'キャンバスの spirit へ' : 'メッセージ',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: _submit, icon: const Icon(Icons.send)),
        ],
      ),
    );
  }

  void _submit() {
    final text = _input.text;
    _input.clear();
    sendUser(text);
  }
}
