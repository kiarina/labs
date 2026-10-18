import 'dart:typed_data';

class ModelFile {
  const ModelFile({
    required this.id,
    required this.url,
    required this.sha256,
    required this.bytes,
    required this.filename,
  });

  /// Directory name in the model store, e.g. 'silero-vad'.
  final String id;
  final String url;
  final String sha256;
  final int bytes;
  final String filename;

  ModelFile withUrl(String url) => ModelFile(id: id, url: url, sha256: sha256, bytes: bytes, filename: filename);

  Map<String, Object?> toJson() => {'id': id, 'url': url, 'sha256': sha256, 'bytes': bytes, 'filename': filename};
}

class ModelProgress {
  const ModelProgress(this.file, this.received, this.total, {this.cached = false});

  final ModelFile file;
  final int received;
  final int total;
  final bool cached;

  double get fraction => total == 0 ? 0 : received / total;
}

abstract class ModelStoreBase {
  /// Downloads [file] if missing (verifying sha256) and returns where a
  /// runtime can load it from: a file path on native, a URL on web.
  Future<String> ensure(ModelFile file, {void Function(ModelProgress)? onProgress});

  /// Reads a small text file (class maps, configs).
  Future<String> readText(ModelFile file);

  /// Bytes of a model (web whisper needs them in memory).
  Future<Uint8List> readBytes(ModelFile file);

  Future<bool> has(ModelFile file);
}
