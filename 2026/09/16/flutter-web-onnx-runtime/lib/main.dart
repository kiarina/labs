import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:web/web.dart' as web;

import 'dfine.dart';

const imageAsset = 'assets/objects_1536x1024_358kb.jpg';

void main() => runApp(const LabApp());

class LabApp extends StatelessWidget {
  const LabApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Flutter Web ONNX Runtime',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const LabPage(),
      );
}

class LabConfig {
  LabConfig.fromUri(Uri uri)
      : ep = uri.queryParameters['ep'] ?? 'wasm',
        warmup = int.tryParse(uri.queryParameters['warmup'] ?? '') ?? 3,
        iterations = int.tryParse(uri.queryParameters['iterations'] ?? '') ?? 20,
        // `model=ceil0` uses the copy whose MaxPool ceil_mode is 0 (WebGPU workaround).
        modelUrl = uri.queryParameters['model'] == 'ceil0'
            ? 'models/model_ceil0.onnx'
            : 'models/model.onnx';

  final String ep;
  final int warmup;
  final int iterations;
  final String modelUrl;

  /// `ep` is a comma-separated preference list, e.g. `webgpu,wasm`.
  List<OrtProvider> get providers => [
        for (final name in ep.split(','))
          switch (name) {
            'webgpu' => OrtProvider.WEB_GPU,
            'webnn' => OrtProvider.WEB_NN,
            'wasm' => OrtProvider.WEB_ASSEMBLY,
            _ => throw ArgumentError('unknown ep: $name'),
          },
      ];
}

class Timings {
  final Map<String, List<double>> samples = {};

  void add(String name, double ms) => samples.putIfAbsent(name, () => []).add(ms);

  static Map<String, double> summarize(List<double> values) {
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values.length > 1
        ? values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / (values.length - 1)
        : 0.0;
    return {
      'mean': mean,
      'min': values.reduce(math.min),
      'max': values.reduce(math.max),
      'stdev': math.sqrt(variance),
    };
  }

  Map<String, Map<String, double>> toJson() => samples.map((k, v) => MapEntry(k, summarize(v)));
}

Future<Uint8List> fetchBytes(String url) async {
  final response = await web.window.fetch(url.toJS).toDart;
  if (!response.ok) throw StateError('GET $url -> ${response.status}');
  final buffer = await response.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

Future<Float32List> fetchFloat32(String url) async =>
    (await fetchBytes(url)).buffer.asFloat32List();

double _ms(Stopwatch sw) => sw.elapsedMicroseconds / 1000.0;

class LabPage extends StatefulWidget {
  const LabPage({super.key});

  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> {
  final config = LabConfig.fromUri(Uri.base);
  final List<String> log = [];
  ui.Image? image;
  List<Detection> detections = [];
  Map<String, Map<String, double>>? benchmark;
  String status = 'running';

  @override
  void initState() {
    super.initState();
    run();
  }

  void _log(String line) {
    debugPrint('[lab] $line');
    setState(() => log.add(line));
  }

  /// One pass through the plugin API: tensor creation, run, output read, disposal.
  Future<(Float32List, Float32List)> infer(
    OrtSession session,
    Float32List input,
    Timings? timings,
  ) async {
    final sw = Stopwatch()..start();
    final tensor = await OrtValue.fromList(input, [1, 3, inputSize, inputSize]);
    timings?.add('create_input_tensor', _ms(sw));

    sw.reset();
    final outputs = await session.run({session.inputNames.first: tensor});
    timings?.add('session_run', _ms(sw));

    sw.reset();
    final logits = Float32List.fromList(
        (await outputs['logits']!.asFlattenedList()).cast<double>());
    final boxes = Float32List.fromList(
        (await outputs['pred_boxes']!.asFlattenedList()).cast<double>());
    timings?.add('read_outputs', _ms(sw));

    sw.reset();
    await tensor.dispose();
    for (final value in outputs.values) {
      await value.dispose();
    }
    timings?.add('dispose', _ms(sw));
    return (logits, boxes);
  }

  Future<void> run() async {
    final result = <String, Object?>{
      'config': {'ep': config.ep, 'model': config.modelUrl, 'bundle': Uri.base.queryParameters['bundle'] ?? 'min', 'warmup': config.warmup, 'iterations': config.iterations},
      'userAgent': web.window.navigator.userAgent,
      'crossOriginIsolated': web.window.crossOriginIsolated,
      'hardwareConcurrency': web.window.navigator.hardwareConcurrency,
    };
    try {
      final ort = globalContext['ort'] as JSObject?;
      if (ort == null) throw StateError('onnxruntime-web (window.ort) is not loaded');
      final env = ort['env'] as JSObject;
      final wasmEnv = env['wasm'] as JSObject;
      result['ortVersion'] = (env['versions'] as JSObject?)?['web']?.dartify();
      _log('onnxruntime-web ${result['ortVersion']}, ep=${config.ep}, '
          'crossOriginIsolated=${result['crossOriginIsolated']}');

      // Labels and image.
      final configJson = jsonDecode(await rootBundle.loadString('assets/config.json'));
      final id2label = (configJson['id2label'] as Map).cast<String, String>();
      final labels = List.generate(id2label.length, (i) => id2label['$i']!);

      var sw = Stopwatch()..start();
      final jpeg = (await rootBundle.load(imageAsset)).buffer.asUint8List();
      final codec = await ui.instantiateImageCodec(jpeg);
      final decoded = (await codec.getNextFrame()).image;
      final rgba = (await decoded.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!
          .buffer
          .asUint8List();
      result['imageDecodeMs'] = _ms(sw);
      setState(() => image = decoded);
      final width = decoded.width, height = decoded.height;
      _log('image ${width}x$height decoded in ${result['imageDecodeMs']} ms');

      // Preprocessing parity against cv2.
      sw = Stopwatch()..start();
      final input = preprocess(rgba, width, height);
      result['firstPreprocessMs'] = _ms(sw);
      final refInput = await fetchFloat32('reference/input.bin');
      final refLogits = await fetchFloat32('reference/logits.bin');
      final refBoxes = await fetchFloat32('reference/pred_boxes.bin');
      result['preprocessParity'] = {
        'maxAbsDiff': maxAbsDiff(input, refInput),
        'differentValues': countDifferent(input, refInput),
        'totalValues': input.length,
      };
      _log('preprocess vs cv2: ${result['preprocessParity']}');

      // Split the preprocessing difference into JPEG decoding and resizing.
      final refRgb = await fetchBytes('reference/decoded_rgb.bin');
      final refRgba = Uint8List(width * height * 4);
      var decodeDiffMax = 0, decodeDiffCount = 0;
      for (var i = 0, j = 0; i < refRgb.length; i += 3, j += 4) {
        for (var c = 0; c < 3; c++) {
          refRgba[j + c] = refRgb[i + c];
          final d = (refRgb[i + c] - rgba[j + c]).abs();
          if (d > 0) decodeDiffCount++;
          if (d > decodeDiffMax) decodeDiffMax = d;
        }
        refRgba[j + 3] = 255;
      }
      final resizedFromRef = preprocess(refRgba, width, height);
      result['decodeParity'] = {
        'maxAbsDiff': decodeDiffMax,
        'differentValues': decodeDiffCount,
        'totalValues': refRgb.length,
      };
      result['resizeParityOnCv2Pixels'] = {
        'maxAbsDiff': maxAbsDiff(resizedFromRef, refInput),
        'differentValues': countDifferent(resizedFromRef, refInput),
      };
      _log('decode vs cv2: ${result['decodeParity']}');
      _log('resize on cv2 pixels vs cv2: ${result['resizeParityOnCv2Pixels']}');

      // Session creation (includes model fetch and wasm/webgpu initialization).
      sw = Stopwatch()..start();
      final session = await OnnxRuntime().createSession(
        config.modelUrl,
        options: OrtSessionOptions(providers: config.providers),
      );
      result['createSessionMs'] = _ms(sw);
      result['wasmNumThreads'] = wasmEnv['numThreads']?.dartify();
      result['inputNames'] = session.inputNames;
      result['outputNames'] = session.outputNames;
      _log('session created in ${result['createSessionMs']} ms, '
          'wasm.numThreads=${result['wasmNumThreads']}');

      // First inference on the browser-preprocessed image.
      sw = Stopwatch()..start();
      final (logits, boxes) = await infer(session, input, null);
      result['firstInferMs'] = _ms(sw);
      final found = postprocess(logits, boxes, labels, width, height);
      setState(() => detections = found);
      result['detections'] = found.map((d) => d.toJson()).toList();
      _log('first inference ${result['firstInferMs']} ms, ${found.length} detections');

      // Runtime parity: identical input tensor as native ONNX Runtime.
      final (refRunLogits, refRunBoxes) = await infer(session, refInput, null);
      result['runtimeParity'] = {
        'logitsMaxAbsDiff': maxAbsDiff(refRunLogits, refLogits),
        'predBoxesMaxAbsDiff': maxAbsDiff(refRunBoxes, refBoxes),
        'detections': postprocess(refRunLogits, refRunBoxes, labels, width, height)
            .map((d) => d.toJson())
            .toList(),
      };
      _log('runtime vs native (same input): logits ${(result['runtimeParity'] as Map)['logitsMaxAbsDiff']}, '
          'boxes ${(result['runtimeParity'] as Map)['predBoxesMaxAbsDiff']}');

      // Benchmark: preprocess + tensor + run + read + postprocess, per phase.
      for (var i = 0; i < config.warmup; i++) {
        await infer(session, preprocess(rgba, width, height), null);
      }
      final timings = Timings();
      for (var i = 0; i < config.iterations; i++) {
        final total = Stopwatch()..start();
        final phase = Stopwatch()..start();
        final x = preprocess(rgba, width, height);
        timings.add('preprocess', _ms(phase));
        final (l, b) = await infer(session, x, timings);
        phase.reset();
        postprocess(l, b, labels, width, height);
        timings.add('postprocess', _ms(phase));
        timings.add('total', _ms(total));
        // Yield so the page stays responsive between iterations.
        await Future<void>.delayed(Duration.zero);
      }
      result['benchmarkMs'] = timings.toJson();
      setState(() => benchmark = timings.toJson());
      _log('benchmark total mean ${timings.toJson()['total']!['mean']!.toStringAsFixed(1)} ms');

      await session.close();
      result['status'] = 'ok';
      setState(() => status = 'ok');
    } catch (e, st) {
      result['status'] = 'error';
      result['error'] = '$e';
      debugPrint('$st');
      _log('ERROR: $e');
      setState(() => status = 'error');
    }
    final json = const JsonEncoder.withIndent('  ').convert(result);
    globalContext['dfineResult'] = json.toJS;
    debugPrint('DFINE_RESULT $json');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('D-FINE on Flutter Web · ${config.ep} · $status')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (image != null)
            AspectRatio(
              aspectRatio: image!.width / image!.height,
              child: CustomPaint(painter: _DetectionPainter(image!, detections)),
            ),
          const SizedBox(height: 16),
          Text('Detections', style: theme.textTheme.titleMedium),
          for (final (i, d) in detections.indexed)
            Text('${i + 1}. ${d.label}  ${d.score.toStringAsFixed(3)}  ${d.bbox}',
                style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 16),
          if (benchmark != null) ...[
            Text('Benchmark (ms, ${config.iterations} iterations)',
                style: theme.textTheme.titleMedium),
            for (final e in benchmark!.entries)
              Text(
                  '${e.key.padRight(20)} mean ${e.value['mean']!.toStringAsFixed(2)}'
                  '  min ${e.value['min']!.toStringAsFixed(2)}'
                  '  max ${e.value['max']!.toStringAsFixed(2)}',
                  style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 16),
          ],
          Text('Log', style: theme.textTheme.titleMedium),
          for (final line in log)
            Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }
}

class _DetectionPainter extends CustomPainter {
  _DetectionPainter(this.image, this.detections);

  final ui.Image image;
  final List<Detection> detections;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / image.width;
    canvas.scale(scale);
    canvas.drawImage(image, Offset.zero, Paint());
    final box = Paint()
      ..color = const Color(0xFF00DC00)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 / scale;
    for (final d in detections) {
      final rect = Rect.fromLTRB(d.bbox[0].toDouble(), d.bbox[1].toDouble(),
          d.bbox[2].toDouble(), d.bbox[3].toDouble());
      canvas.drawRect(rect, box);
      final text = TextPainter(
        text: TextSpan(
          text: ' ${d.label} ${d.score.toStringAsFixed(2)} ',
          style: TextStyle(
              color: Colors.black,
              backgroundColor: const Color(0xFF00DC00),
              fontSize: 14 / scale),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, rect.topLeft);
    }
  }

  @override
  bool shouldRepaint(_DetectionPainter old) => old.detections != detections;
}
