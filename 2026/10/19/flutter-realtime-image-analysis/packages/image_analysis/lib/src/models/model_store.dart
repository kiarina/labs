import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_file.dart';

/// Native model store: `<application support>/models/<id>/<filename>`.
class ModelStore implements ModelStoreBase {
  ModelStore({Directory? root}) : _root = root;

  Directory? _root;
  final _client = http.Client();

  Future<Directory> get root async =>
      _root ??= Directory('${(await getApplicationSupportDirectory()).path}/models');

  Future<File> _file(ModelFile f) async => File('${(await root).path}/${f.id}/${f.filename}');

  @override
  Future<bool> has(ModelFile f) async => (await _file(f)).exists();

  @override
  Future<String> ensure(ModelFile f, {void Function(ModelProgress)? onProgress}) async {
    final file = await _file(f);
    if (await file.exists() && await file.length() == f.bytes) {
      onProgress?.call(ModelProgress(f, f.bytes, f.bytes, cached: true));
      return file.path;
    }
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    if (f.url.startsWith('asset:')) {
      // a model shipped inside the app (not hosted anywhere yet)
      final data = (await rootBundle.load(f.url.substring(6))).buffer.asUint8List();
      final digest = sha256.convert(data).toString();
      if (digest != f.sha256) throw StateError('sha256 mismatch for ${f.url}: $digest != ${f.sha256}');
      await part.writeAsBytes(data);
      await part.rename(file.path);
      onProgress?.call(ModelProgress(f, data.length, data.length));
      return file.path;
    }
    final request = http.Request('GET', Uri.parse(f.url));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw HttpException('GET ${f.url} -> ${response.statusCode}');
    }
    final total = response.contentLength ?? f.bytes;
    final sink = part.openWrite();
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;
    var lastReport = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (received - lastReport > 1 << 20 || received == total) {
          lastReport = received;
          onProgress?.call(ModelProgress(f, received, total));
        }
      }
    } finally {
      await sink.close();
      hasher.close();
    }
    final digest = digestSink.value.toString();
    if (digest != f.sha256) {
      await part.delete();
      throw StateError('sha256 mismatch for ${f.url}: $digest != ${f.sha256}');
    }
    await part.rename(file.path);
    onProgress?.call(ModelProgress(f, received, received));
    return file.path;
  }

  @override
  Future<String> readText(ModelFile f) async => utf8.decode(await readBytes(f));

  @override
  Future<Uint8List> readBytes(ModelFile f) async => (await _file(f)).readAsBytes();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
