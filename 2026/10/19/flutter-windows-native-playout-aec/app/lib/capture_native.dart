import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';

import 'platform/platform.dart';

class CameraCapture {
  CameraController? controller;
  String? get selectedName => controller?.description.name;
  Future<void> start(void Function(Uint8List, int, int, int) onFrame) async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw StateError('No camera');
    final wanted = envValue('camera');
    final camera = wanted != null && wanted.isNotEmpty
        ? cameras.firstWhere(
            (c) => c.name.toLowerCase().contains(wanted.toLowerCase()),
            orElse: () => throw StateError(
              'Requested camera not found: $wanted; available: ${cameras.map((c) => c.name).join(", ")}',
            ),
          )
        : cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
            orElse: () => cameras.first,
          );
    controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );
    await controller!.initialize();
    final clock = Stopwatch()..start();
    await controller!.startImageStream((image) {
      // Small shared CPU buffer for this transport experiment; analysis can
      // independently consume the original full-resolution CameraImage.
      const w = 320;
      final h = (image.height * w / image.width / 2).round() * 2;
      final bytes = Uint8List(w * h * 4);
      final planes = image.planes;
      for (var y = 0; y < h; y++) {
        final sy = y * image.height ~/ h;
        for (var x = 0; x < w; x++) {
          final sx = x * image.width ~/ w, o = (y * w + x) * 4;
          if (image.format.group == ImageFormatGroup.yuv420 &&
              planes.length >= 3) {
            final yy = planes[0].bytes[sy * planes[0].bytesPerRow + sx];
            final u =
                planes[1].bytes[(sy ~/ 2) * planes[1].bytesPerRow +
                    (sx ~/ 2) * (planes[1].bytesPerPixel ?? 1)] -
                128;
            final v =
                planes[2].bytes[(sy ~/ 2) * planes[2].bytesPerRow +
                    (sx ~/ 2) * (planes[2].bytesPerPixel ?? 1)] -
                128;
            final l = (yy - 16) * 1.164;
            bytes[o] = (l + 2.018 * u).round().clamp(0, 255);
            bytes[o + 1] = (l - .391 * u - .813 * v).round().clamp(0, 255);
            bytes[o + 2] = (l + 1.596 * v).round().clamp(0, 255);
          } else {
            final i = sy * planes[0].bytesPerRow + sx * 4;
            bytes[o] = planes[0].bytes[i];
            bytes[o + 1] = planes[0].bytes[i + 1];
            bytes[o + 2] = planes[0].bytes[i + 2];
          }
          bytes[o + 3] = 255;
        }
      }
      onFrame(bytes, w, h, clock.elapsedMicroseconds);
    });
  }

  Future<void> dispose() async {
    final c = controller;
    if (c == null) return;
    if (c.value.isStreamingImages) await c.stopImageStream();
    await c.dispose();
  }
}

CameraCapture createCamera(Object bridge) => CameraCapture();
