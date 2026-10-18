// Native backend (macOS, iOS, Android, Windows): whisper.cpp through dart:ffi.
//
// Each WhisperEngine owns one long-lived background isolate, and that isolate
// owns the whisper_context*. Requests are processed one at a time by the
// isolate's event loop, so calls are serialized and the UI isolate never
// blocks on inference.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'whisper_types.dart';

class WhisperEngine {
  WhisperEngine._(this._isolate, this._sendPort, this._receivePort, this._replies);

  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  final StreamIterator<Object?> _replies;
  Future<void> _queue = Future.value();
  bool _disposed = false;

  /// Loads a ggml model once; reuse the engine for every utterance.
  ///
  /// [path] is a file path. [bytes] (the whole ggml file) is also accepted on
  /// native, which copies it into the context and lets it be freed.
  static Future<WhisperEngine> load({
    String? path,
    Uint8List? bytes,
    bool useGpu = true,
  }) async {
    if ((path == null) == (bytes == null)) {
      throw ArgumentError('Pass exactly one of path or bytes');
    }
    final receivePort = ReceivePort();
    final replies = StreamIterator<Object?>(receivePort);
    final isolate = await Isolate.spawn(
      _workerMain,
      receivePort.sendPort,
      debugName: 'whisper_cpp',
      errorsAreFatal: false,
    );
    await replies.moveNext();
    final sendPort = replies.current as SendPort;
    final engine = WhisperEngine._(isolate, sendPort, receivePort, replies);
    try {
      await engine._call([
        'load',
        path,
        bytes == null ? null : TransferableTypedData.fromList([bytes]),
        useGpu,
      ]);
    } catch (_) {
      engine._shutdown();
      rethrow;
    }
    return engine;
  }

  /// Transcribes 16 kHz mono float32 PCM in [-1, 1].
  Future<WhisperResult> transcribe(
    Float32List pcm16kMono, {
    WhisperOptions options = const WhisperOptions(),
  }) async {
    final reply = await _call([
      'transcribe',
      TransferableTypedData.fromList([pcm16kMono]),
      options.language,
      options.threads,
      options.translate,
      options.noContext,
      options.suppressNonSpeech,
      options.temperature,
      options.audioCtxFor(pcm16kMono.length),
    ]) as List<Object?>;
    final segs = <WhisperSegment>[
      for (final s in reply[1] as List<Object?>)
        WhisperSegment(
          start: (s as List<Object?>)[0] as double,
          end: s[1] as double,
          text: s[2] as String,
        ),
    ];
    return WhisperResult(
      text: reply[0] as String,
      segments: segs,
      language: reply[2] as String,
      elapsed: Duration(microseconds: reply[3] as int),
    );
  }

  /// Frees the whisper context and stops the background isolate.
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await _call(['dispose']);
    } finally {
      _shutdown();
    }
  }

  /// whisper.cpp version and the ggml backends compiled into this build,
  /// e.g. `whisper.cpp v1.9.5 (MTL, BLAS, CPU)`.
  static String get backend {
    final lib = _Lib.instance;
    return lib.backend().cast<Utf8>().toDartString();
  }

  /// whisper_print_system_info() of this build (CPU features etc.).
  static String get systemInfo =>
      _Lib.instance.systemInfo().cast<Utf8>().toDartString();

  Future<Object?> _call(List<Object?> request) {
    if (_disposed) {
      return Future.error(const WhisperException('engine disposed'));
    }
    final c = Completer<Object?>();
    _queue = _queue.then((_) async {
      _sendPort.send(request);
      if (!await _replies.moveNext()) {
        c.completeError(const WhisperException('worker isolate exited'));
        return;
      }
      final r = _replies.current as List<Object?>;
      if (r[0] == true) {
        c.complete(r[1]);
      } else {
        c.completeError(WhisperException(r[1] as String));
      }
    });
    return c.future;
  }

  void _shutdown() {
    _disposed = true;
    _receivePort.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

// ---------------------------------------------------------------------------
// FFI bindings to src/whisper_cpp.h

typedef _InitFileC = Pointer<Void> Function(Pointer<Char>, Int32);
typedef _InitFile = Pointer<Void> Function(Pointer<Char>, int);
typedef _InitBufC = Pointer<Void> Function(Pointer<Void>, Size, Int32);
typedef _InitBuf = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _CtxVoidC = Void Function(Pointer<Void>);
typedef _CtxVoid = void Function(Pointer<Void>);
typedef _TranscribeC = Int32 Function(Pointer<Void>, Pointer<Float>, Int32,
    Pointer<Char>, Int32, Int32, Int32, Int32, Float, Int32);
typedef _Transcribe = int Function(
    Pointer<Void>, Pointer<Float>, int, Pointer<Char>, int, int, int, int, double, int);
typedef _CtxIntC = Int32 Function(Pointer<Void>);
typedef _CtxInt = int Function(Pointer<Void>);
typedef _CtxIdxStrC = Pointer<Char> Function(Pointer<Void>, Int32);
typedef _CtxIdxStr = Pointer<Char> Function(Pointer<Void>, int);
typedef _CtxIdxI64C = Int64 Function(Pointer<Void>, Int32);
typedef _CtxIdxI64 = int Function(Pointer<Void>, int);
typedef _CtxStrC = Pointer<Char> Function(Pointer<Void>);
typedef _CtxStr = Pointer<Char> Function(Pointer<Void>);
typedef _StrC = Pointer<Char> Function();
typedef _IntArgC = Void Function(Int32);
typedef _IntArg = void Function(int);

class _Lib {
  _Lib(DynamicLibrary l)
      : setLogEnabled = l.lookupFunction<_IntArgC, _IntArg>('wcpp_set_log_enabled'),
        initFromFile = l.lookupFunction<_InitFileC, _InitFile>('wcpp_init_from_file'),
        initFromBuffer = l.lookupFunction<_InitBufC, _InitBuf>('wcpp_init_from_buffer'),
        free = l.lookupFunction<_CtxVoidC, _CtxVoid>('wcpp_free'),
        transcribe = l.lookupFunction<_TranscribeC, _Transcribe>('wcpp_transcribe'),
        nSegments = l.lookupFunction<_CtxIntC, _CtxInt>('wcpp_n_segments'),
        segmentText = l.lookupFunction<_CtxIdxStrC, _CtxIdxStr>('wcpp_segment_text'),
        segmentT0 = l.lookupFunction<_CtxIdxI64C, _CtxIdxI64>('wcpp_segment_t0'),
        segmentT1 = l.lookupFunction<_CtxIdxI64C, _CtxIdxI64>('wcpp_segment_t1'),
        resultLanguage = l.lookupFunction<_CtxStrC, _CtxStr>('wcpp_result_language'),
        backend = l.lookupFunction<_StrC, _StrC>('wcpp_backend'),
        systemInfo = l.lookupFunction<_StrC, _StrC>('wcpp_system_info');

  static final _Lib instance = _Lib(_open());

  final _IntArg setLogEnabled;
  final _InitFile initFromFile;
  final _InitBuf initFromBuffer;
  final _CtxVoid free;
  final _Transcribe transcribe;
  final _CtxInt nSegments;
  final _CtxIdxStr segmentText;
  final _CtxIdxI64 segmentT0;
  final _CtxIdxI64 segmentT1;
  final _CtxStr resultLanguage;
  final Pointer<Char> Function() backend;
  final Pointer<Char> Function() systemInfo;

  static DynamicLibrary _open() {
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        return DynamicLibrary.open('whisper_cpp.framework/whisper_cpp');
      } on ArgumentError {
        // Statically linked pods (no use_frameworks!).
        return DynamicLibrary.process();
      }
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libwhisper_cpp.so');
    }
    if (Platform.isWindows) return DynamicLibrary.open('whisper_cpp.dll');
    throw UnsupportedError('whisper_cpp: unsupported platform ${Platform.operatingSystem}');
  }
}

String _utf8(Pointer<Char> p) {
  if (p == nullptr) return '';
  final bytes = p.cast<Uint8>();
  var n = 0;
  while (bytes[n] != 0) {
    n++;
  }
  return utf8.decode(bytes.asTypedList(n), allowMalformed: true);
}

Uint8List _bytes(Pointer<Char> p) {
  if (p == nullptr) return Uint8List(0);
  final bytes = p.cast<Uint8>();
  var n = 0;
  while (bytes[n] != 0) {
    n++;
  }
  return Uint8List.fromList(bytes.asTypedList(n));
}

// ---------------------------------------------------------------------------
// Worker isolate

void _workerMain(SendPort reply) {
  final port = ReceivePort();
  reply.send(port.sendPort);
  final lib = _Lib.instance;
  var ctx = nullptr.cast<Void>();

  port.listen((Object? message) {
    final m = message as List<Object?>;
    try {
      switch (m[0]) {
        case 'load':
          final path = m[1] as String?;
          final data = m[2] as TransferableTypedData?;
          final useGpu = (m[3] as bool) ? 1 : 0;
          if (path != null) {
            final p = path.toNativeUtf8();
            try {
              ctx = lib.initFromFile(p.cast(), useGpu);
            } finally {
              malloc.free(p);
            }
          } else {
            final bytes = data!.materialize().asUint8List();
            final buf = malloc<Uint8>(bytes.length);
            try {
              buf.asTypedList(bytes.length).setAll(0, bytes);
              ctx = lib.initFromBuffer(buf.cast(), bytes.length, useGpu);
            } finally {
              malloc.free(buf);
            }
          }
          if (ctx == nullptr) {
            reply.send([false, 'failed to load model ${path ?? '(bytes)'}']);
          } else {
            reply.send([true, null]);
          }
        case 'transcribe':
          if (ctx == nullptr) throw const WhisperException('no model loaded');
          final pcm = (m[1] as TransferableTypedData).materialize().asFloat32List();
          final lang = (m[2] as String).toNativeUtf8();
          final buf = malloc<Float>(pcm.isEmpty ? 1 : pcm.length);
          try {
            buf.asTypedList(pcm.length).setAll(0, pcm);
            final sw = Stopwatch()..start();
            final rc = lib.transcribe(
              ctx,
              buf,
              pcm.length,
              lang.cast(),
              m[3] as int,
              (m[4] as bool) ? 1 : 0,
              (m[5] as bool) ? 1 : 0,
              (m[6] as bool) ? 1 : 0,
              m[7] as double,
              m[8] as int,
            );
            sw.stop();
            if (rc != 0) throw WhisperException('whisper_full failed ($rc)');
            final n = lib.nSegments(ctx);
            final segs = <List<Object?>>[];
            final all = BytesBuilder(copy: false);
            for (var i = 0; i < n; i++) {
              final raw = lib.segmentText(ctx, i);
              all.add(_bytes(raw));
              segs.add([
                lib.segmentT0(ctx, i) / 100.0,
                lib.segmentT1(ctx, i) / 100.0,
                _utf8(raw).trim(),
              ]);
            }
            // Decode the joined bytes once: a multi-byte character can be split
            // across segment boundaries.
            final text = utf8.decode(all.takeBytes(), allowMalformed: true).trim();
            reply.send([
              true,
              [text, segs, _utf8(lib.resultLanguage(ctx)), sw.elapsedMicroseconds],
            ]);
          } finally {
            malloc.free(buf);
            malloc.free(lang);
          }
        case 'dispose':
          if (ctx != nullptr) lib.free(ctx);
          ctx = nullptr;
          reply.send([true, null]);
          port.close();
      }
    } catch (e) {
      reply.send([false, e is WhisperException ? e.message : e.toString()]);
    }
  });
}
