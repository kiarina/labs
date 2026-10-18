import 'onnx.dart';
import 'onnx_web.dart';

OnnxBackend defaultOnnxBackend({int? threads}) => WebOnnxBackend(threads: threads);
