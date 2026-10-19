import 'local/onnx.dart';
import 'local/onnx_backend_web.dart';

/// onnxruntime-web single-threaded: multi-threading needs cross-origin
/// isolation headers from the host, which a plain static server lacks.
OnnxBackend makeBackend() => defaultOnnxBackend(threads: 1);

/// Web: Flutter serves asset `assets/models/x` at `assets/assets/models/x`;
/// onnxruntime-web fetches it by URL.
Future<OnnxModel> loadModelAsset(OnnxBackend backend, String name) =>
    backend.load('assets/assets/models/$name');
