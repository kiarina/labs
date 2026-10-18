import 'model_file.dart';

/// The models kiarina-agi-image uses by default (kiarina-python 9d483457),
/// same files and sha256. YuNet is the exception: kiarina runs its int8 file
/// through OpenCV, which ONNX Runtime cannot load, so the app ships the
/// float32 file that tools/convert_yunet.py makes from it.
class ModelCatalog {
  static const yunetKiarinaSha256 = '49f000ec501fef24739071fc7e68267d32209045b6822c0c72dce1da25726f10';

  /// Shipped inside the app (made by tools/convert_yunet.py).
  static const yunet = ModelFile(
    id: 'yunet',
    url: 'asset:assets/models/yunet_2023mar_dequantized.onnx',
    sha256: '41a4aaa16542b3bd3632e96230c68d926243be226e31a3703f07c7e3bd2c0f47',
    bytes: 252199,
    filename: 'yunet_2023mar_dequantized.onnx',
  );

  static const sface = ModelFile(
    id: 'sface',
    url: 'https://media.githubusercontent.com/media/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface/face_recognition_sface_2021dec.onnx',
    sha256: '0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79',
    bytes: 38696353,
    filename: 'face_recognition_sface_2021dec.onnx',
  );

  static const dfine = ModelFile(
    id: 'dfine',
    url: 'https://huggingface.co/onnx-community/dfine_s_coco-ONNX/resolve/a3cf03147a9b86c78475139115c8ac142577352d/onnx/model.onnx',
    sha256: 'cd8a49a945feda6d28c6304ae8ae85c2759ba1d78a5a83a22c5ce8db82ef7238',
    bytes: 41535197,
    filename: 'model.onnx',
  );

  static const dfineConfig = ModelFile(
    id: 'dfine',
    url: 'https://huggingface.co/onnx-community/dfine_s_coco-ONNX/resolve/a3cf03147a9b86c78475139115c8ac142577352d/config.json',
    sha256: '9338ef3863d6e95627d4ab06009fa85b1dd523b346b5c3595de2b08862136e99',
    bytes: 6656,
    filename: 'config.json',
  );

  static const siglip2 = ModelFile(
    id: 'siglip2',
    url: 'https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX/resolve/ba1f3b0843f24bc5417d38e19c37b287d719b2f4/onnx/vision_model_int8.onnx',
    sha256: '0dd31785a2713f1113ef2272472165c69d580473dae38d7b47568ac587795e70',
    bytes: 94553333,
    filename: 'vision_model_int8.onnx',
  );

  static const all = [yunet, sface, dfine, dfineConfig, siglip2];
}
