import 'dart:typed_data';

import '../embedding.dart';
import '../image/resize.dart';
import '../image/rgb_image.dart';
import '../onnx.dart';

/// SFace face embedding (128-d, L2-normalized) of an aligned 112x112 face,
/// as OpenCV's FaceRecognizerSF feeds it: RGB, 0..255, NCHW.
class SFace {
  SFace(this.model, {required this.modelSha256});

  final OnnxModel model;
  final String modelSha256;

  /// kiarina's space id for this model, so vectors stay comparable with
  /// what kiarina-agi-image produces.
  EmbeddingSpace get space => EmbeddingSpace(
        kind: 'face',
        spaceId: 'sface:sha256=$modelSha256:size=112:dim=128:norm=l2',
        dimension: 128,
      );

  static Float32List input(RgbImage face) {
    final f = face.width == 112 && face.height == 112 ? face : resizeLinear(face, 112, 112);
    const n = 112 * 112;
    final out = Float32List(3 * n);
    for (var i = 0; i < n; i++) {
      out[i] = f.data[i * 3].toDouble();
      out[n + i] = f.data[i * 3 + 1].toDouble();
      out[2 * n + i] = f.data[i * 3 + 2].toDouble();
    }
    return out;
  }

  Future<Float32List> embed(RgbImage alignedFace) async {
    final o = await model.run({'data': Tensor.float32(input(alignedFace), [1, 3, 112, 112])});
    return l2Normalize(o.values.first.float32);
  }
}

/// SigLIP2 base patch16 224 vision tower (int8), pooled output (768-d,
/// L2-normalized): resize to 224x224, (x / 255 - 0.5) / 0.5, NCHW.
class SigLip2 {
  SigLip2(this.model, {required this.modelSha256});

  final OnnxModel model;
  final String modelSha256;

  /// kiarina calls this space kind "object"; the lab uses the same space for
  /// object crops and whole frames (scenes), so they share one id.
  EmbeddingSpace space(String kind) => EmbeddingSpace(
        kind: kind,
        spaceId: 'siglip2:sha256=$modelSha256:size=224:dim=768:norm=l2',
        dimension: 768,
      );

  static Float32List input(RgbImage image) {
    final r = resizeLinear(image, 224, 224);
    const n = 224 * 224;
    final out = Float32List(3 * n);
    final d = r.data;
    for (var i = 0; i < n; i++) {
      // float32 arithmetic, as numpy does it on float32 arrays
      out[i] = d[i * 3] / 255.0;
      out[n + i] = d[i * 3 + 1] / 255.0;
      out[2 * n + i] = d[i * 3 + 2] / 255.0;
    }
    for (var i = 0; i < out.length; i++) {
      out[i] = (out[i] - 0.5) / 0.5;
    }
    return out;
  }

  Future<Float32List> embed(RgbImage image) async {
    final o = await model.run(
      {'pixel_values': Tensor.float32(input(image), [1, 3, 224, 224])},
      outputs: {'pooler_output'},
    );
    return l2Normalize(o['pooler_output']!.float32);
  }
}
