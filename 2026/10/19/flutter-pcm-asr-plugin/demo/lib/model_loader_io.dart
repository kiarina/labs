import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'local/onnx.dart';
import 'local/onnx_backend_io.dart';

OnnxBackend makeBackend() => defaultOnnxBackend(threads: 2);

/// Native: copy the bundled model to a temporary file, load it, delete it.
Future<OnnxModel> loadModelAsset(OnnxBackend backend, String name) async {
  final data = await rootBundle.load('assets/models/$name');
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/pcm_asr_demo_$name');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
  try {
    return await backend.load(file.path);
  } finally {
    try {
      await file.delete();
    } catch (_) {}
  }
}
