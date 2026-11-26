import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'canvas/behaviors.dart';
import 'canvas/canvas_model.dart';
import 'canvas/canvas_view.dart';
import 'control_server.dart';
import 'demo_scene.dart';
import 'media.dart';
import 'spirit.dart';
import 'spirit_tools.dart';

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
  late final behaviors = CanvasBehaviors(
    canvas,
    wake: (lines) => _send(lines, role: 'event'),
  );
  final canvasKey = GlobalKey();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final Spirit spirit;

  /// `chat` or `canvas`.
  String mode = env('START_MODE', 'canvas');

  /// The spirit's latest words, shown over the canvas.
  ChatEntry? caption;

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
    )..onSpiritText = (e) => setState(() => caption = e);
    spirit.addListener(_spiritChanged);
    canvas.onEvent = _onCanvasEvent;
    _start();
  }

  Future<void> _start() async {
    final model = env('MODEL');
    final effort = env('EFFORT');
    try {
      await spirit.start(
        model: model.isEmpty ? null : model,
        effort: effort.isEmpty ? null : effort,
      );
    } catch (e) {
      setState(() => spirit.status = 'failed: $e');
      return;
    }
    final port = int.tryParse(env('CONTROL_PORT')) ?? 0;
    if (port > 0) _control = await ControlServer.start(port, this);
  }

  @override
  void dispose() {
    _control?.close();
    behaviors.dispose();
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
      '<ui mode="$mode"/>',
      ...behaviors.takeNotices(),
      ...lines,
    ].join('\n');
    return spirit.send(text, role: role, mode: mode);
  }

  Future<void> sendUser(String text) async {
    if (text.trim().isEmpty) return;
    await _send([text], role: 'user');
  }

  void _onCanvasEvent(CanvasEvent e) {
    // The element's own actions and the scripts' handlers run here, at once.
    switch (behaviors.handleEvent(e)) {
      case 'none':
        return;
      case 'later':
        behaviors.notice(_eventLine(e, handled: true));
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

  String _eventLine(CanvasEvent e, {bool handled = false}) =>
      '<canvas_event event="${e.kind}" id="${_attr(e.id)}"'
      '${e.value != null ? ' value="${_attr(e.value is String ? e.value as String : jsonEncode(e.value))}"' : ''}'
      '${handled ? ' handled="on the canvas" at="${e.at.toIso8601String().substring(11, 19)}"' : ''}/>';

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
            'width': kCanvasWidth,
            'height': kCanvasHeight,
            'background': canvas.background,
          },
          'elements': elements,
          ...behaviors.describe(),
        });
        final images = <String>[];
        if (a['image'] as bool? ?? true) {
          // Let a just-changed canvas draw first.
          await WidgetsBinding.instance.endOfFrame;
          final png = await captureCanvas(canvasKey);
          if (png != null) images.add(png);
        }
        return ToolOutcome(text, images: images);
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
        behaviors.reset();
        canvas.state.clear();
        canvas.clear(background: a['background'] as String?);
        return ToolOutcome('ok');
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
        await WidgetsBinding.instance.endOfFrame;
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
      case 'canvas_media':
        return ToolOutcome(jsonEncode(MediaLibrary.instance.list()));
    }
    return ToolOutcome('unknown tool $name', ok: false);
  }

  /// Saves a PNG of the canvas (for the lab's records).
  Future<String?> saveSnapshot(String name) async {
    final dir = env('LOG_DIR');
    if (dir.isEmpty) return null;
    await WidgetsBinding.instance.endOfFrame;
    final png = await captureCanvas(canvasKey, pixelRatio: 1);
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
                      child: CanvasView(
                        controller: canvas,
                        boundaryKey: canvasKey,
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
                      child: _caption(caption!),
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
