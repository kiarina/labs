import 'onnx.dart';

OnnxBackend defaultOnnxBackend({int? threads}) => FlutterOnnxBackend(threads: threads);
