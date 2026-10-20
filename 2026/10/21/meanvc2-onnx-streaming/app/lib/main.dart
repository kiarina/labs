// MeanVC2 ONNX streaming lab app.
//
// Downloads the exported graphs and fixtures from the lab's server
// (py/serve.py), then runs one of:
//   parity  the Kyoko fixture with the fixture noise; compares with the
//           Python ONNX Runtime output of the same graphs
//   bench   160 ms chunks back to back, for every variant/steps/threads in
//           the lists; per-chunk processing time and first-output latency
//   soak    real-time paced conversion (one chunk every 160 ms) for
//           SOAK_SECONDS, sampling memory, thermal state and battery
// and POSTs the JSON report to the server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'meanvc2.dart';

const baseUrl = String.fromEnvironment('BASE_URL', defaultValue: 'http://127.0.0.1:8823');
const mode = String.fromEnvironment('MODE', defaultValue: 'parity,bench');
const tag = String.fromEnvironment('TAG', defaultValue: '');
const variantsList = String.fromEnvironment('VARIANTS', defaultValue: 'fp32,int8');
const stepsList = String.fromEnvironment('STEPS', defaultValue: '2,3');
const threadsList = String.fromEnvironment('ORT_THREADS', defaultValue: '1,2,4');
const trials = int.fromEnvironment('TRIALS', defaultValue: 3);
const soakSeconds = int.fromEnvironment('SOAK_SECONDS', defaultValue: 300);
const autoExit = bool.fromEnvironment('AUTO_EXIT', defaultValue: false);
// OFFLINE: models and fixtures come from the app bundle (assets/serve/) and the
// report is written to the app's documents directory. Used on iOS, where the
// first request to the LAN shows a local network permission prompt.
const offline = bool.fromEnvironment('OFFLINE', defaultValue: false);

const _device = MethodChannel('lab/device');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LabApp());
}

class LabApp extends StatefulWidget {
  const LabApp({super.key});
  @override
  State<LabApp> createState() => _LabAppState();
}

class _LabAppState extends State<LabApp> {
  final _log = <String>[];

  void log(String s) {
    debugPrint('[meanvc2] $s');
    if (mounted) setState(() => _log.add(s));
  }

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final report = <String, dynamic>{
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'processors': Platform.numberOfProcessors,
      'mode': mode,
      'kReleaseMode': kReleaseMode,
      'kProfileMode': kProfileMode,
      'startedAt': DateTime.now().toIso8601String(),
      'device': await _status(),
    };
    try {
      final dir = await _download(report);
      final fx = await _fixtures(dir);
      for (final m in mode.split(',')) {
        if (m == 'parity') report['parity'] = await _parity(dir, fx);
        if (m == 'bench') report['bench'] = await _bench(dir, fx);
        if (m == 'soak') report['soak'] = await _soak(dir, fx);
      }
    } catch (e, st) {
      report['error'] = '$e\n$st';
      log('error: $e');
    }
    report['finishedAt'] = DateTime.now().toIso8601String();
    await _post(report);
    log('report sent');
    if (autoExit) exit(0);
  }

  Future<Map<String, dynamic>> _status() async {
    final s = <String, dynamic>{'rssMb': ProcessInfo.currentRss / 1048576, 'maxRssMb': ProcessInfo.maxRss / 1048576};
    try {
      final m = await _device.invokeMapMethod<String, dynamic>('status');
      if (m != null) s.addAll(m);
    } catch (_) {}
    return s;
  }

  Future<void> _post(Map<String, dynamic> report) async {
    final name = '${Platform.operatingSystem}${tag.isEmpty ? '' : '-$tag'}';
    final body = const JsonEncoder.withIndent(' ').convert(report);
    if (offline) {
      final f = File('${(await getApplicationDocumentsDirectory()).path}/report-$name.json');
      await f.writeAsString(body);
      log('report written: ${f.path}');
      return;
    }
    for (var i = 0; i < 5; i++) {
      try {
        await http.post(Uri.parse('$baseUrl/report/$name'), body: body, headers: {'content-type': 'application/json'});
        return;
      } catch (e) {
        log('post failed: $e');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  // ------------------------------------------------------------ download
  Future<String> _download(Map<String, dynamic> report) async {
    final root = Directory('${(await getApplicationSupportDirectory()).path}/meanvc2');
    await root.create(recursive: true);
    final manifest = jsonDecode(offline
        ? await rootBundle.loadString('assets/serve/manifest.json')
        : (await http.get(Uri.parse('$baseUrl/manifest.json'))).body) as Map<String, dynamic>;
    final sw = Stopwatch()..start();
    var bytes = 0;
    for (final group in ['models', 'fixtures']) {
      await Directory('${root.path}/$group').create(recursive: true);
      for (final e in (manifest[group] as Map<String, dynamic>).entries) {
        final file = File('${root.path}/$group/${e.key}');
        final expected = e.value['sha256'] as String;
        if (await file.exists() && await file.length() == e.value['bytes'] && await _sha(file) == expected) continue;
        log('${offline ? 'unpack' : 'download'} $group/${e.key}');
        if (offline) {
          final data = await rootBundle.load('assets/serve/$group/${e.key}');
          await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
          if (await _sha(file) != expected) throw StateError('sha256 mismatch: ${e.key}');
          bytes += await file.length();
          continue;
        }
        final req = await HttpClient().getUrl(Uri.parse('$baseUrl/$group/${e.key}'));
        final res = await req.close();
        final sink = file.openWrite();
        await res.pipe(sink);
        final got = await _sha(file);
        if (got != expected) throw StateError('sha256 mismatch: ${e.key}');
        bytes += await file.length();
      }
    }
    report['downloadSeconds'] = sw.elapsedMilliseconds / 1000;
    report['downloadedBytes'] = bytes;
    report['manifest'] = manifest;
    return root.path;
  }

  Future<String> _sha(File f) async => (await sha256.bind(f.openRead()).first).toString();

  Future<Map<String, Float32List>> _fixtures(String dir) async {
    final out = <String, Float32List>{};
    for (final f in Directory('$dir/fixtures').listSync().whereType<File>()) {
      final b = await f.readAsBytes();
      out[f.uri.pathSegments.last] = b.buffer.asFloat32List(b.offsetInBytes, b.lengthInBytes ~/ 4);
    }
    return out;
  }

  static Map<String, String> _suffix(String variant) => switch (variant) {
        'fp32' => const {},
        'int8' => const {'asr': '.int8', 'dit': '.int8', 'vocos': '.int8'},
        'int8-asr-dit' => const {'asr': '.int8', 'dit': '.int8'},
        _ => throw ArgumentError(variant),
      };

  static Float32List _chunk(Float32List src, int start) {
    final out = Float32List(kChunk);
    final end = (start + kChunk).clamp(0, src.length);
    out.setAll(0, Float32List.sublistView(src, start, end));
    return out;
  }

  // ------------------------------------------------------------ parity
  Future<List<Map<String, dynamic>>> _parity(String dir, Map<String, Float32List> fx) async {
    final rows = <Map<String, dynamic>>[];
    final source = fx['source.f32']!;
    for (final variant in variantsList.split(',')) {
      if (variant != 'fp32' && variant != 'int8') continue;
      final vc = await MeanVc2Stream.load('$dir/models', suffix: _suffix(variant), threads: 1, steps: 3);
      await vc.setTarget(fx['spk.f32']!);
      final noise = fx['noise.f32']!;
      var pos = 0;
      vc.noiseFn = (n) {
        final o = Float32List.fromList(Float32List.sublistView(noise, pos, pos + n * 80));
        pos += n * 80;
        return o;
      };
      final parts = <double>[];
      for (var i = 0; i < source.length; i += kChunk) {
        parts.addAll(await vc.process(_chunk(source, i)));
      }
      final expected = fx['expected_${variant}_s3.f32']!;
      final n = parts.length < expected.length ? parts.length : expected.length;
      double maxAbs = 0, err = 0, ref = 0;
      for (var i = 0; i < n; i++) {
        final d = (parts[i] - expected[i]).abs();
        if (d > maxAbs) maxAbs = d;
        err += d * d;
        ref += expected[i] * expected[i];
      }
      final snr = 10 * math.log(ref / (err + 1e-30)) / math.ln10;
      rows.add({'variant': variant, 'steps': 3, 'samples': parts.length, 'expectedSamples': expected.length,
        'maxAbs': maxAbs, 'snrDb': snr});
      log('parity $variant: maxAbs=${maxAbs.toStringAsExponential(2)} snr=${snr.toStringAsFixed(1)} dB');
      final name = '${Platform.operatingSystem}${tag.isEmpty ? '' : '-$tag'}-parity_$variant.f32';
      try {
        final bytes = Float32List.fromList(parts).buffer.asUint8List();
        if (offline) {
          await File('${(await getApplicationDocumentsDirectory()).path}/$name').writeAsBytes(bytes);
        } else {
          await http.post(Uri.parse('$baseUrl/report/$name'), body: bytes);
        }
      } catch (e) {
        log('upload failed: $e');
      }
      await vc.close();
    }
    return rows;
  }

  // ------------------------------------------------------------ bench
  Future<List<Map<String, dynamic>>> _bench(String dir, Map<String, Float32List> fx) async {
    final rows = <Map<String, dynamic>>[];
    final source = fx['source.f32']!;
    for (final variant in variantsList.split(',')) {
      for (final threads in threadsList.split(',').map(int.parse)) {
        final before = await _status();
        final vc = await MeanVc2Stream.load('$dir/models', suffix: _suffix(variant), threads: threads);
        await vc.setTarget(fx['spk.f32']!);
        final loaded = await _status();
        for (final steps in stepsList.split(',').map(int.parse)) {
          vc.steps = steps;
          for (var w = 0; w < 3; w++) {
            await vc.process(Float32List(kChunk));
          }
          final times = <double>[];
          final first = <double>[];
          final stage = <String, double>{};
          for (var t = 0; t < trials; t++) {
            await vc.reset();
            var fed = 0;
            double? firstOut;
            for (var i = 0; i < source.length; i += kChunk) {
              final sw = Stopwatch()..start();
              final y = await vc.process(_chunk(source, i));
              final ms = sw.elapsedMicroseconds / 1000;
              fed += kChunk;
              times.add(ms);
              if (y.isNotEmpty && firstOut == null) firstOut = fed / 16 + ms;
            }
            first.add(firstOut ?? -1);
            vc.timing.forEach((k, v) => stage[k] = (stage[k] ?? 0) + v);
          }
          final chunks = source.length / kChunk;
          final row = {
            'variant': variant, 'threads': threads, 'steps': steps, 'loadMs': vc.loadMs,
            ..._summary(times), 'firstOutputMs': first,
            'stageMsPerChunk': stage.map((k, v) => MapEntry(k, v / trials / chunks)),
            'rssBeforeMb': before['rssMb'], 'rssLoadedMb': loaded['rssMb'], 'status': await _status(),
          };
          rows.add(row);
          log('bench $variant t$threads s$steps: p50=${(row['p50Ms'] as double).toStringAsFixed(1)} '
              'p95=${(row['p95Ms'] as double).toStringAsFixed(1)} miss=${row['deadlineMisses']}');
        }
        await vc.close();
      }
    }
    return rows;
  }

  static Map<String, dynamic> _summary(List<double> times) {
    final s = [...times]..sort();
    double pct(double p) => s[((s.length - 1) * p).round()];
    return {
      'chunks': s.length, 'p50Ms': pct(0.5), 'p95Ms': pct(0.95), 'maxMs': s.last,
      'meanMs': s.reduce((a, b) => a + b) / s.length,
      'deadlineMisses': s.where((x) => x > kChunk / 16).length,
    };
  }

  // ------------------------------------------------------------ soak
  Future<Map<String, dynamic>> _soak(String dir, Map<String, Float32List> fx) async {
    final variant = variantsList.split(',').first;
    final threads = int.parse(threadsList.split(',').first);
    final steps = int.parse(stepsList.split(',').first);
    final source = fx['source.f32']!;
    final vc = await MeanVc2Stream.load('$dir/models', suffix: _suffix(variant), threads: threads, steps: steps);
    await vc.setTarget(fx['spk.f32']!);
    final samples = <Map<String, dynamic>>[];
    final windows = <Map<String, dynamic>>[];
    var window = <double>[];
    var late = 0;
    final clock = Stopwatch()..start();
    var next = 0.0;
    var pos = 0;
    var produced = 0;
    samples.add({'t': 0, ...await _status()});
    while (clock.elapsedMilliseconds < soakSeconds * 1000) {
      final wait = next - clock.elapsedMicroseconds / 1000;
      if (wait > 0) await Future.delayed(Duration(microseconds: (wait * 1000).round()));
      if (clock.elapsedMicroseconds / 1000 - next > kChunk / 16) late++;
      final sw = Stopwatch()..start();
      final y = await vc.process(_chunk(source, pos));
      window.add(sw.elapsedMicroseconds / 1000);
      produced += y.length;
      pos += kChunk;
      if (pos >= source.length) pos = 0;
      next += kChunk / 16;
      if (window.length >= 62) {
        // about 10 s
        final t = clock.elapsedMilliseconds / 1000;
        windows.add({'t': t, ..._summary(window)});
        samples.add({'t': t, ...await _status()});
        final w = windows.last;
        log('soak t=${t.toStringAsFixed(0)} p50=${(w['p50Ms'] as double).toStringAsFixed(1)} '
            'p95=${(w['p95Ms'] as double).toStringAsFixed(1)} miss=${w['deadlineMisses']} ${samples.last}');
        window = [];
      }
    }
    await vc.close();
    return {'variant': variant, 'threads': threads, 'steps': steps, 'seconds': soakSeconds,
      'producedSeconds': produced / 16000, 'lateStarts': late, 'windows': windows, 'samples': samples};
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: Text('MeanVC2 ONNX · $mode')),
          body: ListView(padding: const EdgeInsets.all(12), children: [for (final l in _log) Text(l)]),
        ),
      );
}
