import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final stream = await navigator.mediaDevices.getUserMedia({
    'audio': true,
    'video': false,
  });
  await Future<void>.delayed(const Duration(seconds: 4));
  for (final track in stream.getTracks()) {
    await track.stop();
  }
  await stream.dispose();
  exit(0);
}
