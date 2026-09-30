// The Windows shader compile stall with plain Flutter: no flutter_scene, no
// Flutter GPU. A heavy FragmentProgram is drawn with one blend mode, then with
// a second, and the app records how long the first frame of each takes.
//
// Settings (environment variables; the result goes to OUT, since a Windows
// release app has no stdout): OUT=<path>, EXIT=1 (default) quits at the end.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

final env = Platform.environment;
final out = File(
  env['OUT'] ??
      '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_only.txt',
);
final started = Stopwatch()..start();

void log(String line) {
  final stamped =
      '[${(started.elapsedMilliseconds / 1000).toStringAsFixed(2)}s] $line';
  stdout.writeln(stamped);
  out.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
}

Future<void> main() async {
  if (out.existsSync()) out.deleteSync();
  WidgetsFlutterBinding.ensureInitialized();
  final cheap = await ui.FragmentProgram.fromAsset('shaders/cheap.frag');
  final heavy = await ui.FragmentProgram.fromAsset('shaders/heavy.frag');
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xFF3060A0), BlendMode.src);
  final image = await recorder.endRecording().toImage(64, 64);
  log('start: ${Platform.operatingSystem}');
  runApp(Repro(cheap: cheap, heavy: heavy, image: image));
}

class Repro extends StatefulWidget {
  const Repro({
    super.key,
    required this.cheap,
    required this.heavy,
    required this.image,
  });

  final ui.FragmentProgram cheap;
  final ui.FragmentProgram heavy;
  final ui.Image image;

  @override
  State<Repro> createState() => _ReproState();
}

class _ReproState extends State<Repro> with SingleTickerProviderStateMixin {
  // What is drawn: 0 = cheap only, 1 = + heavy (srcOver), 2 = + heavy (plus).
  int stage = 0;
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker;
  final List<FrameTiming> _timings = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((e) => _time.value = e.inMicroseconds / 1e6)
      ..start();
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
    _run();
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    log('cheap shader on screen');
    for (final (next, label) in [
      (1, 'heavy shader, BlendMode.srcOver'),
      (2, 'the same heavy shader, BlendMode.plus'),
    ]) {
      _timings.clear();
      final watch = Stopwatch()..start();
      setState(() => stage = next);
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      watch.stop();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final raster = _timings.isEmpty
          ? -1
          : _timings
                .map((t) => t.rasterDuration.inMilliseconds)
                .reduce((a, b) => a > b ? a : b);
      log('$label: ${watch.elapsedMilliseconds} ms, max raster $raster ms');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    log('done');
    if ((env['EXIT'] ?? '1') == '1') exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: CustomPaint(
        painter: _Painter(widget, stage, _time),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Painter extends CustomPainter {
  _Painter(this.widget, this.stage, this.time) : super(repaint: time);

  final Repro widget;
  final int stage;
  final ValueNotifier<double> time;

  ui.FragmentShader _shader(ui.FragmentProgram program, Size size) {
    final shader = program.fragmentShader()
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time.value);
    if (identical(program, widget.heavy))
      shader.setImageSampler(0, widget.image);
    return shader;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final third = Rect.fromLTWH(0, 0, size.width / 3, size.height);
    canvas.drawRect(third, Paint()..shader = _shader(widget.cheap, size));
    if (stage >= 1) {
      canvas.drawRect(
        third.shift(Offset(size.width / 3, 0)),
        Paint()..shader = _shader(widget.heavy, size),
      );
    }
    if (stage >= 2) {
      canvas.drawRect(
        third.shift(Offset(2 * size.width / 3, 0)),
        Paint()
          ..shader = _shader(widget.heavy, size)
          ..blendMode = BlendMode.plus,
      );
    }
  }

  @override
  bool shouldRepaint(_Painter old) => old.stage != stage;
}
