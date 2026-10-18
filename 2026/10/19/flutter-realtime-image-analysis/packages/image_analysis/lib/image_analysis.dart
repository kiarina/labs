/// Real-time camera frame analysis ported from kiarina-agi-image: faces
/// (YuNet + SFace), objects (D-FINE + SigLIP2 on crops), scenes (SigLIP2 on
/// the whole frame), tracked into entities that keep their embeddings.
library;

export 'src/embedding.dart';
export 'src/image/align.dart';
export 'src/image/resize.dart';
export 'src/image/rgb_image.dart';
export 'src/models/catalog.dart';
export 'src/models/detectors.dart';
export 'src/models/embedders.dart';
export 'src/models/model_file.dart';
export 'src/models/model_store_io.dart' if (dart.library.js_interop) 'src/models/model_store_web.dart';
export 'src/onnx.dart';
export 'src/onnx_backend_io.dart' if (dart.library.js_interop) 'src/onnx_backend_web.dart';
export 'src/sight/sight.dart';
