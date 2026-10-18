// Flutter web check of the whisper_cpp WebAssembly backend.
//
// Query parameters (all optional, URLs relative to the page):
//   model=<url of ggml-*.bin>   wav=<url of 16 kHz mono s16 wav>
//   runs=<n> (default 2)        threads=<n> (0 = all)
//   worker=<url of whisper_worker.js> (default: the package asset)
//   fit=1 (WhisperOptions.fitAudioCtx)   variant=auto|st|mt   bytes=1 (fetch the model in Dart, load(bytes:))
// The result is also published as `window.resultJson` for headless runs
// (web/harness/run_headless.mjs).
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
// This example is web-only and uses the web-only extras (workerUrl, variant,
// load timings), so it imports the web implementation directly. Apps that
// target every platform import only package:whisper_cpp/whisper_cpp.dart.
import 'package:whisper_cpp/src/whisper_web.dart'; // ignore: implementation_imports
import 'package:whisper_cpp/whisper_cpp.dart' hide WhisperEngine;

void main() => runApp(const MaterialApp(home: CheckPage()));

class CheckPage extends StatefulWidget {
  const CheckPage({super.key});
  @override
  State<CheckPage> createState() => _CheckPageState();
}

class _CheckPageState extends State<CheckPage> {
  final _log = <String>[];
  int _frames = 0;
  double _maxGapMs = 0;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _say(String s) {
    debugPrint(s);
    setState(() => _log.add(s));
  }

  // Counts animation frames and the longest gap between two of them while
  // whisper runs, to show the UI thread is not blocked.
  void _frameLoop() {
    double? last;
    void tick(double t) {
      if (last != null && t - last! > _maxGapMs) _maxGapMs = t - last!;
      last = t;
      _frames++;
      if (_busy) web.window.requestAnimationFrame(tick.toJS);
    }

    web.window.requestAnimationFrame(tick.toJS);
  }

  Future<void> _run() async {
    final q = Uri.base.queryParameters;
    final modelUrl = q['model'] ?? '../../../../../models/whisper/ggml-tiny.bin';
    final wavUrl = q['wav'] ?? '../../../../../work/conversation_16k.wav';
    final runs = int.tryParse(q['runs'] ?? '') ?? 2;
    final threads = int.tryParse(q['threads'] ?? '') ?? 0;
    if (q['worker'] != null) WhisperEngine.workerUrl = q['worker'];
    if (q['variant'] != null) WhisperEngine.variant = q['variant']!;
    final out = <String, Object?>{
      'model': modelUrl,
      'crossOriginIsolated': web.window.crossOriginIsolated,
      'hc': web.window.navigator.hardwareConcurrency,
      'ua': web.window.navigator.userAgent,
      'backend': WhisperEngine.backend,
      'runs': <Object?>[],
    };
    try {
      _say('backend: ${WhisperEngine.backend}');
      final pcm = _readWav(await _fetch(wavUrl));
      _say('audio: ${(pcm.length / 16000).toStringAsFixed(2)} s');

      final sw = Stopwatch()..start();
      final engine = q['bytes'] == '1'
          ? await WhisperEngine.load(
              bytes: (await _fetch(modelUrl)).buffer.asUint8List())
          : await WhisperEngine.load(path: modelUrl);
      out['loadMs'] = sw.elapsedMicroseconds / 1000;
      out['fetchMs'] = engine.modelFetchTime.inMicroseconds / 1000;
      out['initMs'] = engine.modelInitTime.inMicroseconds / 1000;
      out['variant'] = engine.loadedVariant;
      out['maxThreads'] = engine.threads;
      out['systemInfo'] = WhisperEngine.systemInfo;
      _say('load ${out['loadMs']} ms (fetch ${out['fetchMs']}, init ${out['initMs']}) '
          'variant=${engine.loadedVariant} maxThreads=${engine.threads}');

      _frameLoop();
      for (var i = 0; i < runs; i++) {
        _frames = 0;
        _maxGapMs = 0;
        final w = Stopwatch()..start();
        final r = await engine.transcribe(pcm, options: WhisperOptions(threads: threads, fitAudioCtx: q['fit'] == '1'));
        final wallMs = w.elapsedMicroseconds / 1000;
        (out['runs'] as List).add({
          ...r.toJson(),
          'wallMs': wallMs,
          'frames': _frames,
          'maxFrameGapMs': _maxGapMs,
        });
        _say('run$i whisper ${r.elapsed.inMilliseconds} ms, wall ${wallMs.round()} ms, '
            'frames $_frames, max frame gap ${_maxGapMs.round()} ms, lang ${r.language}');
        _say(r.text);
        for (final s in r.segments) {
          _say('  $s');
        }
      }
      _busy = false;
      await engine.dispose();
      out['done'] = true;
      _say('DONE');
    } catch (e, st) {
      out['error'] = '$e\n$st';
      _say('ERROR $e');
    }
    _busy = false;
    setState(() {});
    // Published as JSON text: run_headless.mjs reads window.resultJson.
    globalContext.setProperty('resultJson'.toJS, jsonEncode(out).toJS);
  }

  static Future<ByteData> _fetch(String url) async {
    final res = await web.window.fetch(url.toJS).toDart;
    if (!res.ok) throw Exception('fetch $url: ${res.status}');
    final buf = await res.arrayBuffer().toDart;
    return buf.toDart.asByteData();
  }

  static Float32List _readWav(ByteData v) {
    var off = 12;
    int? ch, rate, bits, dataOff, dataLen;
    while (off + 8 <= v.lengthInBytes) {
      final id = String.fromCharCodes(v.buffer.asUint8List(v.offsetInBytes + off, 4));
      final len = v.getUint32(off + 4, Endian.little);
      if (id == 'fmt ') {
        ch = v.getUint16(off + 10, Endian.little);
        rate = v.getUint32(off + 12, Endian.little);
        bits = v.getUint16(off + 22, Endian.little);
      } else if (id == 'data') {
        dataOff = off + 8;
        dataLen = len;
      }
      off += 8 + len + (len & 1);
    }
    if (ch != 1 || rate != 16000 || bits != 16 || dataOff == null) {
      throw Exception('need 16 kHz mono s16 wav');
    }
    final n = dataLen! ~/ 2;
    final pcm = Float32List(n);
    for (var i = 0; i < n; i++) {
      pcm[i] = v.getInt16(dataOff + i * 2, Endian.little) / 32768.0;
    }
    return pcm;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('whisper.cpp wasm')),
        body: Column(children: [
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [for (final l in _log) SelectableText(l)],
            ),
          ),
        ]),
      );
}
