// whisper_cpp example / benchmark.
//
// Loads each requested ggml model once, transcribes a 16 kHz WAV twice
// (cold + warm) on the same engine, then disposes it. Results are shown on
// screen, printed as JSON lines prefixed with `WHISPER_BENCH ` and optionally
// written to a JSON file.
//
// Configuration (environment variable wins over --dart-define of the same name):
//   WHISPER_MODELS_DIR  directory with ggml-<name>.bin
//   WHISPER_MODELS      comma list, default "base"
//   WHISPER_WAV         16 kHz WAV (PCM16 or float32, mono or multi-channel)
//   WHISPER_LANGUAGE    default "ja"
//   WHISPER_USE_GPU     "0" to force CPU
//   WHISPER_BENCH_OUT   optional JSON output path
//   WHISPER_BENCH_EXIT  "1" to exit the app when done (desktop)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:whisper_cpp/whisper_cpp.dart';

String _cfg(String key, String fallback) {
  final env = Platform.environment[key];
  if (env != null && env.isNotEmpty) return env;
  final defs = <String, String>{
    'WHISPER_MODELS_DIR': const String.fromEnvironment('WHISPER_MODELS_DIR'),
    'WHISPER_MODELS': const String.fromEnvironment('WHISPER_MODELS'),
    'WHISPER_WAV': const String.fromEnvironment('WHISPER_WAV'),
    'WHISPER_LANGUAGE': const String.fromEnvironment('WHISPER_LANGUAGE'),
    'WHISPER_USE_GPU': const String.fromEnvironment('WHISPER_USE_GPU'),
    'WHISPER_BENCH_OUT': const String.fromEnvironment('WHISPER_BENCH_OUT'),
    'WHISPER_BENCH_EXIT': const String.fromEnvironment('WHISPER_BENCH_EXIT'),
  };
  final d = defs[key];
  return (d == null || d.isEmpty) ? fallback : d;
}

/// Minimal RIFF/WAVE reader: PCM16 or IEEE float32, downmixed to mono.
/// The sample rate must already be 16 kHz.
Float32List readWav16k(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }
  var off = 12;
  int? format, channels, rate, bits;
  while (off + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(off, off + 4));
    final size = bd.getUint32(off + 4, Endian.little);
    final body = off + 8;
    if (id == 'fmt ') {
      format = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      rate = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE) format = bd.getUint16(body + 24, Endian.little);
    } else if (id == 'data') {
      if (rate != 16000) throw FormatException('expected 16 kHz, got $rate');
      final ch = channels!;
      final bps = bits! ~/ 8;
      final frames = size ~/ (bps * ch);
      final out = Float32List(frames);
      for (var i = 0; i < frames; i++) {
        var acc = 0.0;
        for (var c = 0; c < ch; c++) {
          final p = body + (i * ch + c) * bps;
          if (format == 1 && bits == 16) {
            acc += bd.getInt16(p, Endian.little) / 32768.0;
          } else if (format == 3 && bits == 32) {
            acc += bd.getFloat32(p, Endian.little);
          } else {
            throw FormatException('unsupported WAV format $format/$bits');
          }
        }
        out[i] = acc / ch;
      }
      return out;
    }
    off = body + size + (size & 1);
  }
  throw const FormatException('no data chunk');
}

void main() => runApp(const BenchApp());

class BenchApp extends StatefulWidget {
  const BenchApp({super.key});
  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> {
  final _lines = <String>[];

  void _log(String s) {
    // ignore: avoid_print
    print(s);
    setState(() => _lines.add(s));
  }

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    _log('backend: ${WhisperEngine.backend}');
    final modelsDir = _cfg('WHISPER_MODELS_DIR', '');
    final wavPath = _cfg('WHISPER_WAV', '');
    if (modelsDir.isEmpty || wavPath.isEmpty) {
      _log('Set WHISPER_MODELS_DIR and WHISPER_WAV (env or --dart-define).');
      return;
    }
    final models = _cfg('WHISPER_MODELS', 'base').split(',').map((s) => s.trim());
    final language = _cfg('WHISPER_LANGUAGE', 'ja');
    final useGpu = _cfg('WHISPER_USE_GPU', '1') != '0';
    final results = <Map<String, Object?>>[];
    try {
      final pcm = readWav16k(await File(wavPath).readAsBytes());
      _log('audio: ${(pcm.length / 16000).toStringAsFixed(2)} s');
      for (final m in models) {
        final path = '$modelsDir/ggml-$m.bin';
        final sw = Stopwatch()..start();
        final engine = await WhisperEngine.load(path: path, useGpu: useGpu);
        final loadMs = sw.elapsedMilliseconds;
        _log('[$m] load $loadMs ms');
        final opts = WhisperOptions(language: language);
        final runs = <Map<String, Object?>>[];
        WhisperResult? last;
        for (var i = 0; i < 3; i++) {
          sw.reset();
          final r = await engine.transcribe(pcm, options: opts);
          final wall = sw.elapsedMilliseconds;
          runs.add({'run': i + 1, 'wallMs': wall, 'whisperMs': r.elapsed.inMilliseconds});
          _log('[$m] run ${i + 1}: ${r.elapsed.inMilliseconds} ms (wall $wall ms)');
          last = r;
        }
        _log('[$m] ${last!.language}: ${last.text}');
        sw.reset();
        await engine.dispose();
        final disposeMs = sw.elapsedMilliseconds;
        var afterDispose = 'no error (unexpected)';
        try {
          await engine.transcribe(pcm, options: opts);
        } on WhisperException catch (e) {
          afterDispose = e.message;
        }
        _log('[$m] dispose $disposeMs ms; transcribe after dispose -> $afterDispose');
        final rec = {
          'model': m,
          'backend': WhisperEngine.backend,
          'useGpu': useGpu,
          'audioSec': pcm.length / 16000,
          'loadMs': loadMs,
          'runs': runs,
          'disposeMs': disposeMs,
          'afterDispose': afterDispose,
          'result': last.toJson(),
        };
        results.add(rec);
        // ignore: avoid_print
        print('WHISPER_BENCH ${jsonEncode(rec)}');
      }
      _log('done');
    } catch (e, st) {
      _log('error: $e\n$st');
    }
    final out = _cfg('WHISPER_BENCH_OUT', '');
    if (out.isNotEmpty) {
      await File(out).writeAsString(const JsonEncoder.withIndent('  ').convert({
        'systemInfo': WhisperEngine.systemInfo,
        'results': results,
      }));
    }
    if (_cfg('WHISPER_BENCH_EXIT', '0') == '1') exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('whisper_cpp')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [for (final l in _lines) SelectableText(l)],
        ),
      ),
    );
  }
}
