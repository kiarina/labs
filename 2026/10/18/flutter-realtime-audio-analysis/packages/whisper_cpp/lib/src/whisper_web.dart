// Web backend: whisper.cpp compiled to WebAssembly, running in a Web Worker.
//
// The worker (assets/whisper_web/whisper_worker.js, staged together with the
// wasm builds by tool/build_web.sh) owns the whisper_context. Requests are
// answered in order, so calls are serialized and the UI thread never blocks
// on inference. See WEB.md for building and hosting (COOP/COEP headers for
// the multi-threaded build).

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'whisper_types.dart';

class WhisperEngine {
  WhisperEngine._(this._worker) {
    _worker.onmessage = ((web.MessageEvent e) => _onMessage(e)).toJS;
    _worker.onerror = ((web.Event e) => _failAll(_describeError(e))).toJS;
  }

  final web.Worker _worker;
  final Map<int, Completer<Map<Object?, Object?>>> _pending = {};
  int _nextId = 1;
  bool _disposed = false;
  Map<Object?, Object?> _info = const {};

  /// URL of whisper_worker.js. The default is the package asset
  /// (`assets/packages/whisper_cpp/assets/whisper_web/whisper_worker.js`,
  /// resolved by Flutter's asset manager). Set it before [load] when the
  /// files are hosted elsewhere; whisper_st.* / whisper_mt.* must sit next to
  /// the worker script. Web only.
  static String? workerUrl;

  /// Which wasm build to use: `auto` (multi-threaded when the page is
  /// cross-origin isolated, else single-threaded), `st` or `mt`. Web only.
  static String variant = 'auto';

  /// Loads a ggml model once; reuse the engine for every utterance.
  ///
  /// On the web, [path] is a URL (relative URLs resolve against the page)
  /// that the worker fetches itself, and [bytes] is the whole ggml file
  /// (copied to the worker; the caller's list stays usable). [useGpu] is
  /// ignored: this wasm build has only the CPU (SIMD128) backend.
  static Future<WhisperEngine> load({
    String? path,
    Uint8List? bytes,
    bool useGpu = true,
  }) async {
    if ((path == null) == (bytes == null)) {
      throw ArgumentError('Pass exactly one of path or bytes');
    }
    final url = workerUrl ??
        ui_web.assetManager
            .getAssetUrl('packages/whisper_cpp/assets/whisper_web/whisper_worker.js');
    final engine = WhisperEngine._(web.Worker(url.toJS));
    try {
      engine._info = await engine._call({
        'cmd': 'init'.toJS,
        'variant': variant.toJS,
        if (path != null) 'modelUrl': Uri.base.resolve(path).toString().toJS,
        if (bytes != null) 'modelBytes': bytes.toJS,
      });
      _lastSystemInfo = engine._info['systemInfo'] as String?;
    } catch (_) {
      engine._shutdown();
      rethrow;
    }
    return engine;
  }

  /// Transcribes 16 kHz mono float32 PCM in [-1, 1].
  ///
  /// `options.threads` 0 uses every pre-spawned thread of the multi-threaded
  /// build (see [threads]); the single-threaded build always uses 1.
  Future<WhisperResult> transcribe(
    Float32List pcm16kMono, {
    WhisperOptions options = const WhisperOptions(),
  }) async {
    final r = await _call({
      'cmd': 'transcribe'.toJS,
      'pcm': pcm16kMono.toJS,
      'language': options.language.toJS,
      'threads': options.threads.toJS,
      'translate': options.translate.toJS,
      'noContext': options.noContext.toJS,
      'suppressNonSpeech': options.suppressNonSpeech.toJS,
      'temperature': options.temperature.toJS,
      'audioCtx': options.audioCtxFor(pcm16kMono.length).toJS,
    });
    return WhisperResult(
      text: r['text'] as String,
      segments: [
        for (final s in r['segments'] as List<Object?>)
          WhisperSegment(
            start: _num((s as Map<Object?, Object?>)['t0Ms']) / 1000.0,
            end: _num(s['t1Ms']) / 1000.0,
            text: s['text'] as String,
          ),
      ],
      language: r['language'] as String,
      elapsed: Duration(microseconds: (_num(r['elapsedMs']) * 1000).round()),
    );
  }

  /// Frees the whisper context and terminates the worker.
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await _call({'cmd': 'dispose'.toJS});
    } finally {
      _shutdown();
    }
  }

  /// whisper.cpp version and the build that [load] picks on this page.
  static String get backend =>
      'whisper.cpp v1.9.5 (wasm32, SIMD128, CPU, '
      '${_wantsMt() ? 'multi-threaded' : 'single-threaded'})';

  /// whisper_print_system_info() of the wasm build, known after the first
  /// [load] (empty before).
  static String get systemInfo => _lastSystemInfo ?? '';
  static String? _lastSystemInfo;

  /// Build actually loaded by this engine: `st` or `mt`. Web only.
  String get loadedVariant => _info['variant'] as String? ?? '';

  /// Maximum threads per transcription (pool size + 1, or 1). Web only.
  int get threads => _num(_info['maxThreads']).toInt();

  /// Time the worker spent fetching the model (0 for [load] with bytes) and
  /// inside whisper_init_from_buffer. Web only, for measurements.
  Duration get modelFetchTime => _ms(_info['fetchMs']);
  Duration get modelInitTime => _ms(_info['initMs']);

  static bool _wantsMt() =>
      variant == 'mt' || (variant == 'auto' && web.window.crossOriginIsolated);

  Future<Map<Object?, Object?>> _call(Map<String, JSAny?> request) {
    if (_disposed) {
      return Future.error(const WhisperException('engine disposed'));
    }
    final id = _nextId++;
    final c = Completer<Map<Object?, Object?>>();
    _pending[id] = c;
    final obj = JSObject()..setProperty('id'.toJS, id.toJS);
    request.forEach((k, v) => obj.setProperty(k.toJS, v));
    // Structured clone copies the typed arrays, so the caller's lists stay
    // valid (no transfer).
    _worker.postMessage(obj);
    return c.future;
  }

  void _onMessage(web.MessageEvent e) {
    final data = e.data.dartify() as Map<Object?, Object?>;
    final c = _pending.remove(_num(data['id']).toInt());
    if (c == null) return;
    if (data['ok'] == true) {
      c.complete(data);
    } else {
      c.completeError(WhisperException('${data['error']}'));
    }
  }

  void _failAll(String message) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final c in pending) {
      c.completeError(WhisperException(message));
    }
  }

  void _shutdown() {
    _disposed = true;
    _worker.terminate();
    _failAll('engine disposed');
  }

  static String _describeError(web.Event e) {
    if (e.isA<web.ErrorEvent>()) {
      final ee = e as web.ErrorEvent;
      return 'worker error: ${ee.message} (${ee.filename}:${ee.lineno})';
    }
    return 'worker error (failed to load whisper_worker.js?)';
  }

  static double _num(Object? v) => (v as num?)?.toDouble() ?? 0;
  static Duration _ms(Object? v) =>
      Duration(microseconds: (_num(v) * 1000).round());
}
