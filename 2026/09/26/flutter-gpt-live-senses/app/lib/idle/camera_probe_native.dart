import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import 'camera_probe.dart';

/// Camera frames via `camera` (Android / iOS) and `camera_desktop`
/// (macOS / Windows), converted to RGB at [outWidth] every [interval].
final class CameraProbe {
  final ResolutionPreset preset;
  final Duration interval;
  final int outWidth;
  final FrameStats stats = FrameStats();
  CameraController? controller;
  String? cameraName;

  CameraProbe({
    this.preset = ResolutionPreset.high,
    this.interval = const Duration(milliseconds: 200),
    this.outWidth = 320,
  });

  Future<void> start() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw StateError('no camera');
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    cameraName = camera.name;
    final c = controller = CameraController(
      camera,
      preset,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );
    await c.initialize();
    await c.startImageStream(_onImage);
  }

  void _onImage(CameraImage image) {
    final fmt = image.format.group.name;
    if (!stats.onFrame(
      image.width,
      image.height,
      fmt,
      image.planes.length,
      interval,
    )) {
      return;
    }
    final t0 = stats.clock.elapsedMicroseconds;
    final p = image.planes;
    final rgb = image.format.group == ImageFormatGroup.yuv420 && p.length >= 3
        ? rgbFromYuv420(
            p[0].bytes,
            p[0].bytesPerRow,
            p[1].bytes,
            p[2].bytes,
            p[1].bytesPerRow,
            p[1].bytesPerPixel ?? 1,
            image.width,
            image.height,
            outWidth,
          )
        : rgbFrom4Channel(
            p[0].bytes,
            image.width,
            image.height,
            p[0].bytesPerRow,
            outWidth,
            bgra: true,
          );
    stats.recordConversion(stats.clock.elapsedMicroseconds - t0, rgb);
  }

  Widget preview() {
    final c = controller;
    if (c == null || !c.value.isInitialized) return const SizedBox();
    return CameraPreview(c);
  }

  Map<String, Object?> toJson() => {
    'camera': cameraName,
    'preset': preset.name,
    ...stats.toJson(),
  };

  Future<void> stop() async {
    final c = controller;
    if (c == null) return;
    if (c.value.isStreamingImages) await c.stopImageStream();
    await c.dispose();
  }
}
