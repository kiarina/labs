import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../media.dart';
import 'canvas_model.dart';
import 'vrm_element.dart';
import 'web_host.dart';

/// Parses `#RGB`, `#RRGGBB`, `#RRGGBBAA` and a few names.
Color? parseColor(Object? v) {
  if (v is! String) return null;
  const names = {
    'white': Colors.white,
    'black': Colors.black,
    'red': Colors.red,
    'green': Colors.green,
    'blue': Colors.blue,
    'yellow': Colors.yellow,
    'orange': Colors.orange,
    'purple': Colors.purple,
    'pink': Colors.pink,
    'gray': Colors.grey,
    'grey': Colors.grey,
    'transparent': Colors.transparent,
  };
  final s = v.trim().toLowerCase();
  if (names[s] case final c?) return c;
  if (!s.startsWith('#')) return null;
  var hex = s.substring(1);
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  if (hex.length == 6) hex = '${hex}ff';
  if (hex.length != 8) return null;
  final n = int.tryParse(hex, radix: 16);
  if (n == null) return null;
  // RRGGBBAA -> AARRGGBB
  return Color(((n & 0xff) << 24) | (n >> 8));
}

/// The canvas: a fixed 1280x800 stage scaled to fit, with the elements the
/// spirit put on it. [boundaryKey] lets the spirit's `canvas_view` take a
/// picture of it.
class CanvasView extends StatefulWidget {
  const CanvasView({
    super.key,
    required this.controller,
    required this.boundaryKey,
  });

  final CanvasController controller;
  final GlobalKey boundaryKey;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  CanvasController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _ticker.dispose();
    super.dispose();
  }

  bool get _needsTicks =>
      c.animating ||
      c.elements.values.any(
        (e) => e.type == 'svg' && (e.props['frames'] as List?) != null,
      );

  void _changed() {
    if (_needsTicks && !_ticker.isActive) _ticker.start();
    if (mounted) setState(() {});
  }

  void _onTick(Duration _) {
    c.settle();
    if (!_needsTicks) _ticker.stop();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final background = parseColor(c.background) ?? const Color(0xFF15171C);
    return FittedBox(
      fit: BoxFit.contain,
      child: RepaintBoundary(
        key: widget.boundaryKey,
        child: ClipRect(
          child: Container(
            width: kCanvasWidth,
            height: kCanvasHeight,
            color: background,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (final e in c.ordered)
                  if (e.flag('visible', true)) _positioned(e),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _positioned(CanvasElement e) {
    final v = c.currentValues(e);
    Widget child = _ElementBody(
      key: ValueKey('${e.id}:${e.type}'),
      element: e,
      controller: c,
      now: c.now,
    );
    if (e.flag('tappable', false)) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => c.emit(
          CanvasEvent('tap', e.id, {
            'x': (v['x']! + d.localPosition.dx).round(),
            'y': (v['y']! + d.localPosition.dy).round(),
          }),
        ),
        child: child,
      );
    }
    return Positioned(
      left: v['x'],
      top: v['y'],
      width: math.max(0, v['w']!),
      height: math.max(0, v['h']!),
      child: Opacity(
        opacity: v['opacity']!.clamp(0, 1),
        child: Transform.rotate(
          angle: v['rotation']! * math.pi / 180,
          child: Transform.scale(scale: v['scale']!, child: child),
        ),
      ),
    );
  }
}

class _ElementBody extends StatelessWidget {
  const _ElementBody({
    super.key,
    required this.element,
    required this.controller,
    required this.now,
  });

  final CanvasElement element;
  final CanvasController controller;
  final Duration now;

  CanvasElement get e => element;

  TextStyle _textStyle({double size = 28, Color? color}) => TextStyle(
    fontSize: e.num_('size', size),
    color: parseColor(e.props['color']) ?? color ?? Colors.white,
    fontWeight: switch (e.str('weight')) {
      'bold' => FontWeight.w700,
      'light' => FontWeight.w300,
      _ => FontWeight.w400,
    },
    height: 1.35,
  );

  @override
  Widget build(BuildContext context) {
    switch (e.type) {
      case 'text':
        return Container(
          padding: EdgeInsets.all(e.num_('padding', 0)),
          decoration: BoxDecoration(
            color: parseColor(e.props['background']),
            borderRadius: BorderRadius.circular(e.num_('radius', 0)),
          ),
          alignment: switch (e.str('align')) {
            'center' => Alignment.center,
            'right' => Alignment.centerRight,
            _ => Alignment.centerLeft,
          },
          child: Text(
            controller.render(e.str('text') ?? ''),
            textAlign: switch (e.str('align')) {
              'center' => TextAlign.center,
              'right' => TextAlign.right,
              _ => TextAlign.left,
            },
            style: _textStyle(),
          ),
        );
      case 'shape':
        final fill = parseColor(e.props['fill']);
        final stroke = parseColor(e.props['stroke']);
        final sw = e.num_('stroke_width', stroke == null ? 0 : 2);
        final ellipse = e.str('shape') == 'ellipse';
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            shape: ellipse ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: ellipse
                ? null
                : BorderRadius.circular(e.num_('radius', 0)),
            border: stroke == null
                ? null
                : Border.all(color: stroke, width: sw),
          ),
        );
      case 'image':
        final r = MediaLibrary.instance.resolve(e.str('src'));
        final fit = e.str('fit') == 'cover' ? BoxFit.cover : BoxFit.contain;
        final img = r == null
            ? _missing('image "${e.str('src')}" not found')
            : r.file != null
            ? Image.file(r.file!, fit: fit)
            : Image.network(
                r.url!,
                fit: fit,
                errorBuilder: (_, err, _) => _missing('$err'),
              );
        return ClipRRect(
          borderRadius: BorderRadius.circular(e.num_('radius', 0)),
          child: img,
        );
      case 'svg':
        final frames = (e.props['frames'] as List?)?.cast<Object?>();
        String? markup;
        if (frames != null && frames.isNotEmpty) {
          final fps = e.num_('fps', 6).clamp(0.5, 30);
          final i = (now.inMicroseconds / 1e6 * fps).floor();
          final loop = e.flag('loop', true);
          markup =
              frames[loop ? i % frames.length : math.min(i, frames.length - 1)]
                  ?.toString();
        } else {
          markup = e.str('markup');
        }
        if (markup == null || markup.isEmpty) {
          return _missing('svg without markup');
        }
        return SvgPicture.string(
          markup,
          fit: BoxFit.contain,
          errorBuilder: (_, err, _) => _missing('svg: $err'),
        );
      case 'video':
        return _VideoElement(element: e, controller: controller);
      case 'audio':
        return _AudioElement(element: e, controller: controller);
      case 'vrm':
        return VrmElementView(element: e);
      case 'button':
        return _ButtonElement(element: e, controller: controller);
      case 'choices':
        return _ChoicesElement(element: e, controller: controller);
      case 'input':
        return _InputElement(element: e, controller: controller);
      case 'web':
        return _WebElement(element: e);
    }
    return _missing('unknown type ${e.type}');
  }
}

Widget _missing(String text) => Container(
  color: const Color(0x33FF5555),
  alignment: Alignment.center,
  padding: const EdgeInsets.all(4),
  child: Text(
    text,
    style: const TextStyle(color: Colors.white70, fontSize: 12),
  ),
);

class _ButtonElement extends StatelessWidget {
  const _ButtonElement({required this.element, required this.controller});

  final CanvasElement element;
  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final color = parseColor(e.props['color']) ?? const Color(0xFF6C8CFF);
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: parseColor(e.props['text_color']) ?? Colors.white,
        textStyle: TextStyle(
          fontSize: e.num_('size', 22),
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(e.num_('radius', 14)),
        ),
      ),
      onPressed: e.flag('disabled', false)
          ? null
          : () => controller.emit(CanvasEvent('press', e.id)),
      child: Text(controller.render(e.str('label') ?? e.id)),
    );
  }
}

class _ChoicesElement extends StatefulWidget {
  const _ChoicesElement({required this.element, required this.controller});

  final CanvasElement element;
  final CanvasController controller;

  @override
  State<_ChoicesElement> createState() => _ChoicesElementState();
}

class _ChoicesElementState extends State<_ChoicesElement> {
  final _picked = <String>{};

  @override
  Widget build(BuildContext context) {
    final e = widget.element;
    final options = [
      for (final o in (e.props['options'] as List? ?? const []))
        o is Map
            ? (
                value: '${o['value'] ?? o['label']}',
                label: '${o['label'] ?? o['value']}',
              )
            : (value: '$o', label: '$o'),
    ];
    final multi = e.flag('multiple', false);
    final size = e.num_('size', 20);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: parseColor(e.props['background']) ?? const Color(0x22FFFFFF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (e.str('label') case final label?)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  label,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size + 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final o in options)
                  multi
                      ? FilterChip(
                          label: Text(
                            o.label,
                            style: TextStyle(fontSize: size),
                          ),
                          selected: _picked.contains(o.value),
                          onSelected: (on) => setState(
                            () => on
                                ? _picked.add(o.value)
                                : _picked.remove(o.value),
                          ),
                        )
                      : ActionChip(
                          label: Text(
                            o.label,
                            style: TextStyle(fontSize: size),
                          ),
                          onPressed: () => widget.controller.emit(
                            CanvasEvent('choose', e.id, o.value),
                          ),
                        ),
              ],
            ),
            if (multi)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: FilledButton(
                  onPressed: () => widget.controller.emit(
                    CanvasEvent('choose', e.id, _picked.toList()),
                  ),
                  child: Text(e.str('submit_label') ?? 'OK'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InputElement extends StatefulWidget {
  const _InputElement({required this.element, required this.controller});

  final CanvasElement element;
  final CanvasController controller;

  @override
  State<_InputElement> createState() => _InputElementState();
}

class _InputElementState extends State<_InputElement> {
  late final _text = TextEditingController(text: widget.element.str('value'));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    widget.controller.emit(
      CanvasEvent('submit', widget.element.id, _text.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.element;
    final multiline = e.flag('multiline', false);
    return Material(
      color: Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: TextField(
              controller: _text,
              maxLines: multiline ? null : 1,
              expands: multiline,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                fontSize: e.num_('size', 20),
                color: Colors.white,
              ),
              onChanged: (v) => widget.controller.inputValues[e.id] = v,
              onSubmitted: multiline ? null : (_) => _submit(),
              decoration: InputDecoration(
                hintText: e.str('placeholder'),
                filled: true,
                fillColor: const Color(0x22FFFFFF),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _submit,
            child: Text(e.str('submit_label') ?? '送信'),
          ),
        ],
      ),
    );
  }
}

class _VideoElement extends StatefulWidget {
  const _VideoElement({required this.element, required this.controller});

  final CanvasElement element;
  final CanvasController controller;

  @override
  State<_VideoElement> createState() => _VideoElementState();
}

class _VideoElementState extends State<_VideoElement> {
  VideoPlayerController? _video;
  String? _src;
  String? _error;
  bool _endedSent = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(covariant _VideoElement oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.element.str('src') != _src) {
      _open();
    } else {
      _applyPlaying();
    }
  }

  Future<void> _open() async {
    final e = widget.element;
    _src = e.str('src');
    await _video?.dispose();
    _video = null;
    _endedSent = false;
    final r = MediaLibrary.instance.resolve(_src);
    if (r == null) {
      setState(() => _error = 'video "$_src" not found');
      return;
    }
    final v = r.file != null
        ? VideoPlayerController.file(r.file!)
        : VideoPlayerController.networkUrl(Uri.parse(r.url!));
    try {
      await v.initialize();
    } on Object catch (err) {
      if (mounted) setState(() => _error = '$err');
      return;
    }
    if (!mounted) {
      await v.dispose();
      return;
    }
    v.addListener(_onVideo);
    setState(() {
      _video = v;
      _error = null;
    });
    _applyPlaying();
  }

  void _applyPlaying() {
    final v = _video;
    if (v == null) return;
    final e = widget.element;
    v.setLooping(e.flag('loop', false));
    v.setVolume(e.flag('muted', false) ? 0 : e.num_('volume', 1));
    if (e.flag('playing', e.flag('autoplay', true))) {
      if (!v.value.isPlaying && !_ended(v)) v.play();
    } else if (v.value.isPlaying) {
      v.pause();
    }
  }

  bool _ended(VideoPlayerController v) =>
      v.value.duration > Duration.zero && v.value.position >= v.value.duration;

  void _onVideo() {
    final v = _video;
    if (v == null) return;
    if (!v.value.isLooping && _ended(v) && !_endedSent) {
      _endedSent = true;
      widget.controller.emit(CanvasEvent('ended', widget.element.id));
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    if (_error != null) return _missing(_error!);
    if (v == null) return const SizedBox();
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.element.num_('radius', 0)),
      child: FittedBox(
        fit: widget.element.str('fit') == 'cover'
            ? BoxFit.cover
            : BoxFit.contain,
        child: SizedBox(
          width: v.value.size.width,
          height: v.value.size.height,
          child: VideoPlayer(v),
        ),
      ),
    );
  }
}

class _AudioElement extends StatefulWidget {
  const _AudioElement({required this.element, required this.controller});

  final CanvasElement element;
  final CanvasController controller;

  @override
  State<_AudioElement> createState() => _AudioElementState();
}

class _AudioElementState extends State<_AudioElement> {
  final _player = AudioPlayer();
  String? _src;
  String? _error;
  PlayerState _state = PlayerState.stopped;
  late final StreamSubscription<void> _done;
  late final StreamSubscription<PlayerState> _states;

  @override
  void initState() {
    super.initState();
    _done = _player.onPlayerComplete.listen((_) {
      widget.controller.emit(CanvasEvent('ended', widget.element.id));
    });
    _states = _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _open();
  }

  @override
  void didUpdateWidget(covariant _AudioElement oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.element.str('src') != _src) {
      _open();
    } else {
      _apply();
    }
  }

  Future<void> _open() async {
    _src = widget.element.str('src');
    final r = MediaLibrary.instance.resolve(_src);
    if (r == null) {
      setState(() => _error = 'audio "$_src" not found');
      return;
    }
    try {
      await _player.stop();
      await _player.setSource(
        r.file != null ? DeviceFileSource(r.file!.path) : UrlSource(r.url!),
      );
      _error = null;
      await _apply();
    } on Object catch (err) {
      if (mounted) setState(() => _error = '$err');
    }
  }

  Future<void> _apply() async {
    final e = widget.element;
    await _player.setReleaseMode(
      e.flag('loop', false) ? ReleaseMode.loop : ReleaseMode.stop,
    );
    await _player.setVolume(e.num_('volume', 1).clamp(0, 1));
    final play = e.flag('playing', e.flag('autoplay', true));
    if (play &&
        _state != PlayerState.playing &&
        _state != PlayerState.completed) {
      await _player.resume();
    } else if (!play && _state == PlayerState.playing) {
      await _player.pause();
    }
  }

  @override
  void dispose() {
    _done.cancel();
    _states.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _missing(_error!);
    final playing = _state == PlayerState.playing;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x22FFFFFF),
        borderRadius: BorderRadius.circular(999),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          IconButton(
            color: Colors.white,
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            onPressed: () => playing ? _player.pause() : _player.resume(),
          ),
          Expanded(
            child: Text(
              widget.element.str('label') ?? (_src ?? '').split('/').last,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

/// A PNG of the canvas as it is drawn now (base64), at [pixelRatio] of the
/// 1280x800 stage.
Future<String?> captureCanvas(GlobalKey key, {double pixelRatio = 0.75}) async {
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) return null;
  final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (bytes == null) return null;
  return base64Encode(bytes.buffer.asUint8List());
}

/// A `web` element: a web view showing the element's `html`, served by
/// [WebHost] (so `asset://` works and the page has the `sg` object).
class _WebElement extends StatefulWidget {
  const _WebElement({required this.element});

  final CanvasElement element;

  @override
  State<_WebElement> createState() => _WebElementState();
}

class _WebElementState extends State<_WebElement> {
  late final WebViewController _web;
  String? _html;
  int _version = 0;

  WebHost get host => WebHost.instance;

  @override
  void initState() {
    super.initState();
    final id = widget.element.id;
    // Pages may play sound without a click first (WebKit asks for one by
    // default: NotSupportedError from Audio.play()).
    _web = WebViewController.fromPlatformCreationParams(
      Platform.isMacOS || Platform.isIOS
          ? WebKitWebViewControllerCreationParams(
              mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
            )
          : const PlatformWebViewControllerCreationParams(),
    )..setJavaScriptMode(JavaScriptMode.unrestricted);
    // A transparent background is not implemented for macOS's web view
    // (UnimplementedError: opaque); the page paints its own.
    if (!Platform.isMacOS) _web.setBackgroundColor(const Color(0x00000000));
    _web.addJavaScriptChannel(
      'SGHost',
      onMessageReceived: (m) => host.receive(id, m.message),
    );
    host.controllers[id] = _web;
    _load();
  }

  @override
  void didUpdateWidget(covariant _WebElement oldWidget) {
    super.didUpdateWidget(oldWidget);
    host.controllers[widget.element.id] = _web;
    if (widget.element.str('html') != _html) _load();
  }

  void _load() {
    final e = widget.element;
    _html = e.str('html');
    final url = e.str('url');
    if (_html != null) {
      host.setPage(e.id, _html!);
      _web.loadRequest(Uri.parse(host.pageUrl(e.id, ++_version)));
    } else if (url != null && url.startsWith('https://')) {
      _web.loadRequest(Uri.parse(url));
    }
  }

  @override
  void dispose() {
    if (identical(host.controllers[widget.element.id], _web)) {
      host.controllers.remove(widget.element.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.element.num_('radius', 0)),
      child: WebViewWidget(controller: _web),
    );
  }
}
