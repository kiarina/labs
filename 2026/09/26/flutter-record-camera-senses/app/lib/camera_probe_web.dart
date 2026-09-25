import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'camera_probe.dart';

/// `camera_web` has no image stream, so the web reads frames itself:
/// getUserMedia → MediaStreamTrackProcessor → VideoFrame.copyTo(RGBA).
final class CameraProbe {
  final Duration interval;
  final int outWidth;
  final FrameStats stats = FrameStats();
  web.MediaStream? _stream;
  web.ReadableStreamDefaultReader? _reader;
  bool _running = false;
  Uint8List? _buffer;
  String? cameraName;

  CameraProbe({
    Object? preset,
    this.interval = const Duration(milliseconds: 200),
    this.outWidth = 320,
  });

  Future<void> start() async {
    final stream = _stream = await web.window.navigator.mediaDevices
        .getUserMedia(
          web.MediaStreamConstraints(
            video: {
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            }.jsify()!,
          ),
        )
        .toDart;
    final track = stream.getVideoTracks().toDart.first;
    cameraName = track.label;
    final processor = web.MediaStreamTrackProcessor(
      web.MediaStreamTrackProcessorInit(track: track, maxBufferSize: 1),
    );
    _reader = processor.readable.getReader() as web.ReadableStreamDefaultReader;
    _running = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (_running) {
      final result = await _reader!.read().toDart;
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
    final w = frame.codedWidth;
    final h = frame.codedHeight;
    if (!stats.onFrame(w, h, frame.format ?? '?', 1, interval)) return;
    final t0 = stats.clock.elapsedMicroseconds;
    final size = w * h * 4;
    final buffer = (_buffer != null && _buffer!.length == size)
        ? _buffer!
        : (_buffer = Uint8List(size));
    await frame
        .copyTo(buffer.toJS, web.VideoFrameCopyToOptions(format: 'RGBA'))
        .toDart;
    final rgb = rgbFrom4Channel(buffer, w, h, w * 4, outWidth, bgra: false);
    stats.recordConversion(stats.clock.elapsedMicroseconds - t0, rgb);
  }

  Widget preview() => const SizedBox();

  Map<String, Object?> toJson() => {
    'camera': cameraName,
    'preset': 'getUserMedia 1280x720',
    ...stats.toJson(),
  };

  Future<void> stop() async {
    _running = false;
    await _reader?.cancel().toDart;
    for (final t
        in _stream?.getTracks().toDart ?? const <web.MediaStreamTrack>[]) {
      t.stop();
    }
  }
}
