import 'dart:typed_data';

import 'web_bridge.dart';

CameraCapture createCamera(CaptureBridge bridge) => CameraCapture(bridge);

class CameraCapture {
  final CaptureBridge bridge;
  CameraCapture(this.bridge);
  Future<void> start(void Function(Uint8List, int, int, int) onFrame) =>
      bridge.startCamera(onFrame);
  Future<void>
  dispose() async {} // The bridge owns and releases the browser camera.
}
