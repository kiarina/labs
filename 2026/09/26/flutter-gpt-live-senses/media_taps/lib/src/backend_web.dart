import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamTrackWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

import '../media_taps.dart';

MediaTapsBackend createBackend() => _WebBackend();

/// Batches 10 ms (480 frames at 48 kHz) of the first channel as Int16 and
/// transfers it to the main thread, matching the native 10 ms chunks.
const _workletSource = r'''
class PcmTap extends AudioWorkletProcessor {
  constructor() { super(); this.size = Math.round(sampleRate / 100); this.buf = new Int16Array(this.size); this.n = 0; }
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch) return true;
    for (let i = 0; i < ch.length; i++) {
      const v = Math.max(-1, Math.min(1, ch[i]));
      this.buf[this.n++] = v * 32767;
      if (this.n === this.size) {
        this.port.postMessage(this.buf, [this.buf.buffer]);
        this.buf = new Int16Array(this.size);
        this.n = 0;
      }
    }
    return true;
  }
}
registerProcessor('pcm-tap', PcmTap);
''';

const _maxQueuedFrames = 8;
const _maxQueuedPcmSamples = 48000;

final class _WebBackend implements MediaTapsBackend {
  final Map<int, _Tap> _taps = {};
  int _nextId = 1;
  web.AudioContext? _context;
  Future<void>? _workletReady;

  @override
  String get platform => 'web';

  @override
  Future<int> attach(
    MediaStreamTrack track, {
    required bool local,
    MediaStream? stream,
    TapOptions options = const TapOptions(),
  }) async {
    final jsTrack = (track as MediaStreamTrackWeb).jsTrack;
    final id = _nextId++;
    final _Tap tap;
    if (track.kind == 'video') {
      tap = _VideoTap(id, jsTrack, options);
    } else {
      final context = _context ??= web.AudioContext();
      await (_workletReady ??= _loadWorklet(context));
      tap = _AudioTap(id, jsTrack, context, options, remote: !local);
    }
    _taps[id] = tap;
    await tap.start();
    return id;
  }

  Future<void> _loadWorklet(web.AudioContext context) async {
    final blob = web.Blob(
      [_workletSource.toJS].toJS,
      web.BlobPropertyBag(type: 'application/javascript'),
    );
    final url = web.URL.createObjectURL(blob);
    await context.audioWorklet.addModule(url).toDart;
    await context.resume().toDart;
  }

  @override
  Future<void> detach(int id) async => _taps.remove(id)?.stop();

  @override
  Future<List<TapSnapshot>> poll() async => [
    for (final tap in _taps.values) tap.drain(),
  ];
}

sealed class _Tap {
  final int id;
  final TapOptions options;
  final Map<String, Object?> counters = {'callbacks': 0};

  _Tap(this.id, this.options);

  Future<void> start();
  void stop();
  TapSnapshot drain();

  void _inc(String key, [int by = 1]) =>
      counters[key] = ((counters[key] as int?) ?? 0) + by;
}

final class _VideoTap extends _Tap {
  final web.MediaStreamTrack track;
  web.ReadableStreamDefaultReader? _reader;
  bool _running = false;
  Uint8List? _buffer;
  final List<VideoPayload> _queue = [];

  _VideoTap(super.id, this.track, super.options);

  @override
  Future<void> start() async {
    final processor = web.MediaStreamTrackProcessor(
      web.MediaStreamTrackProcessorInit(track: track, maxBufferSize: 1),
    );
    _reader = processor.readable.getReader() as web.ReadableStreamDefaultReader;
    _running = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    final reader = _reader!;
    while (_running) {
      final result = await reader.read().toDart;
      if (result.done) break;
      final frame = result.value as web.VideoFrame;
      try {
        await _onFrame(frame);
      } finally {
        frame.close();
      }
    }
  }

  Future<void> _onFrame(web.VideoFrame frame) async {
    _inc('callbacks');
    final w = frame.codedWidth;
    final h = frame.codedHeight;
    counters['width'] = w;
    counters['height'] = h;
    counters['rotation'] = 0;
    counters['bufferType'] = frame.format;
    if (options.convertWidth == 0) return;

    final sw = Stopwatch()..start();
    final size = frame.allocationSize();
    final buffer = (_buffer != null && _buffer!.length == size)
        ? _buffer!
        : (_buffer = Uint8List(size));
    final layout = (await frame.copyTo(buffer.toJS).toDart).toDart;
    final y = layout.first;
    final dw = options.convertWidth < 0 ? w : options.convertWidth;
    final dh = (h * dw ~/ w) & ~1;
    final luma = Uint8List(dw * dh);
    // Nearest-neighbour downscale of the Y plane (the native side uses
    // libyuv's box filter; this only has to be cheap and representative).
    for (var row = 0; row < dh; row++) {
      final src = y.offset + (row * h ~/ dh) * y.stride;
      final dst = row * dw;
      for (var col = 0; col < dw; col++) {
        luma[dst + col] = buffer[src + col * w ~/ dw];
      }
    }
    sw.stop();
    final us = sw.elapsedMicroseconds;
    _inc('convertCount');
    _inc('convertUsTotal', us);
    counters['convertUsMax'] = math.max(
      (counters['convertUsMax'] as int?) ?? 0,
      us,
    );
    if (options.deliver) {
      if (_queue.length >= _maxQueuedFrames) {
        _queue.removeAt(0);
        _inc('droppedToDart');
      }
      _queue.add(VideoPayload(dw, dh, luma));
    }
  }

  @override
  void stop() {
    _running = false;
    _reader?.cancel();
  }

  @override
  TapSnapshot drain() {
    final frames = List<VideoPayload>.of(_queue);
    _queue.clear();
    return TapSnapshot(
      id: id,
      kind: TapKind.video,
      counters: Map.of(counters),
      frames: frames,
    );
  }
}

final class _AudioTap extends _Tap {
  final web.MediaStreamTrack track;
  final web.AudioContext context;
  final bool remote;
  web.MediaStreamAudioSourceNode? _source;
  web.AudioWorkletNode? _node;
  web.HTMLAudioElement? _element;
  double _sumSquares = 0;
  int _samples = 0;
  final List<Int16List> _pcm = [];
  int _pcmSamples = 0;

  _AudioTap(
    super.id,
    this.track,
    this.context,
    super.options, {
    required this.remote,
  });

  @override
  Future<void> start() async {
    final stream = web.MediaStream([track].toJS);
    if (remote) {
      // Chrome delivers silence for a remote WebRTC track to WebAudio unless
      // the stream is also playing in a media element.
      final element = _element = web.HTMLAudioElement()
        ..muted = true
        ..autoplay = true
        ..srcObject = stream;
      unawaited(element.play().toDart.catchError((_) => null));
    }
    final source = _source = context.createMediaStreamSource(stream);
    final node = _node = web.AudioWorkletNode(context, 'pcm-tap');
    node.port.onmessage = ((web.MessageEvent e) {
      _onChunk((e.data as JSInt16Array).toDart);
    }).toJS;
    source.connect(node);
    node.connect(context.destination);
    counters['sampleRate'] = context.sampleRate.round();
    counters['channels'] = 1;
    counters['bitsPerSample'] = 16;
  }

  void _onChunk(Int16List chunk) {
    _inc('callbacks');
    counters['framesPerChunk'] = chunk.length;
    for (final s in chunk) {
      _sumSquares += s * s;
    }
    _samples += chunk.length;
    if (options.deliver) {
      if (_pcmSamples + chunk.length > _maxQueuedPcmSamples) {
        _inc('droppedToDart');
        return;
      }
      _pcm.add(chunk);
      _pcmSamples += chunk.length;
    }
  }

  @override
  void stop() {
    _source?.disconnect();
    _node?.disconnect();
    _element?.pause();
  }

  @override
  TapSnapshot drain() {
    counters['rms'] = _samples == 0
        ? null
        : math.sqrt(_sumSquares / _samples) / 32768;
    _sumSquares = 0;
    _samples = 0;
    Int16List? pcm;
    if (_pcm.isNotEmpty) {
      pcm = Int16List(_pcmSamples);
      var offset = 0;
      for (final c in _pcm) {
        pcm.setRange(offset, offset + c.length, c);
        offset += c.length;
      }
      _pcm.clear();
      _pcmSamples = 0;
    }
    return TapSnapshot(
      id: id,
      kind: TapKind.audio,
      counters: Map.of(counters),
      pcm: pcm,
    );
  }
}
