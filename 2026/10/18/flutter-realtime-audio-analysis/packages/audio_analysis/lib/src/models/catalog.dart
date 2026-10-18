import 'model_file.dart';

/// The models kiarina-agi-audio uses by default (kiarina-python 9d483457),
/// with the same sha256. YAMNet is the TFLite converted to ONNX in this lab;
/// its URL is set by the app (it is not hosted anywhere yet).
class ModelCatalog {
  static const sileroVad = ModelFile(
    id: 'silero-vad',
    url: 'https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx',
    sha256: '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3',
    bytes: 2327524,
    filename: 'silero_vad.onnx',
  );

  static const pyannoteSegmentation = ModelFile(
    id: 'pyannote-segmentation-3.0',
    url: 'https://huggingface.co/onnx-community/pyannote-segmentation-3.0/resolve/main/onnx/model.onnx',
    sha256: '057ee564753071c0b09b5b611648b50ac188d50846bff5f01e9f7bbf1591ea25',
    bytes: 5986908,
    filename: 'model.onnx',
  );

  static const ecapaTdnn = ModelFile(
    id: 'ecapa-tdnn-onnx',
    url: 'https://huggingface.co/pranjal-pravesh/ecapa_tdnn_onnx/resolve/04c3ffe4fd00b3b7853fd57db44e2e531d4817f2/ecapa_tdnn.onnx',
    sha256: '245eb5995cfffd74494862dee33da2b00c1c2579eb0c6703847784e9901ed458',
    bytes: 84028639,
    filename: 'ecapa_tdnn.onnx',
  );

  static const clapAudio = ModelFile(
    id: 'clap-onnx',
    url: 'https://huggingface.co/Xenova/clap-htsat-unfused/resolve/main/onnx/audio_model.onnx',
    sha256: 'a1c2b43c44f71e0fa841a4b86700886c199bf87699ea45632c4d831bc6c88957',
    bytes: 117528416,
    filename: 'audio_model.onnx',
  );

  static const yamnetClassMap = ModelFile(
    id: 'yamnet',
    url: 'https://raw.githubusercontent.com/tensorflow/models/5c597f85268743140854f0e670f2175e8668553a/research/audioset/yamnet/yamnet_class_map.csv',
    sha256: 'cdf24d193e196d9e95912a2667051ae203e92a2ba09449218ccb40ef787c6df2',
    bytes: 14096,
    filename: 'yamnet_class_map.csv',
  );

  /// Filled in by the app (url) from the lab's conversion (sha256/bytes).
  static ModelFile yamnetOnnx({required String url, required String sha256, required int bytes}) =>
      ModelFile(id: 'yamnet', url: url, sha256: sha256, bytes: bytes, filename: 'yamnet.onnx');
}
