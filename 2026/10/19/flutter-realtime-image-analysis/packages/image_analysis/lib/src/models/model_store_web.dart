import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'model_file.dart';

/// Web model store: keeps verified bytes in memory for this page and returns
/// the URL (the browser's HTTP cache serves later loads). Persisting across
/// reloads (Cache Storage / OPFS) is left open in the lab.
class ModelStore implements ModelStoreBase {
  ModelStore();

  final _bytes = <String, Uint8List>{};

  @override
  Future<bool> has(ModelFile f) async => _bytes.containsKey(f.url);

  @override
  Future<String> ensure(ModelFile f, {void Function(ModelProgress)? onProgress}) async {
    if (_bytes.containsKey(f.url)) {
      onProgress?.call(ModelProgress(f, f.bytes, f.bytes, cached: true));
      return f.url.startsWith('asset:') ? 'assets/${f.url.substring(6)}' : f.url;
    }
    if (f.url.startsWith('asset:')) {
      final key = f.url.substring(6);
      final data = (await rootBundle.load(key)).buffer.asUint8List();
      final digest = sha256.convert(data).toString();
      if (digest != f.sha256) throw StateError('sha256 mismatch for ${f.url}: $digest != ${f.sha256}');
      _bytes[f.url] = data;
      onProgress?.call(ModelProgress(f, data.length, data.length));
      // Flutter web serves asset `k` at `assets/k`
      return 'assets/$key';
    }
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', Uri.parse(f.url)));
      if (response.statusCode != 200) {
        throw StateError('GET ${f.url} -> ${response.statusCode}');
      }
      final total = response.contentLength ?? f.bytes;
      final builder = BytesBuilder(copy: false);
      var lastReport = 0;
      await for (final chunk in response.stream) {
        builder.add(chunk);
        if (builder.length - lastReport > 1 << 20) {
          lastReport = builder.length;
          onProgress?.call(ModelProgress(f, builder.length, total));
        }
      }
      final bytes = builder.takeBytes();
      final digest = sha256.convert(bytes).toString();
      if (digest != f.sha256) {
        throw StateError('sha256 mismatch for ${f.url}: $digest != ${f.sha256}');
      }
      _bytes[f.url] = bytes;
      onProgress?.call(ModelProgress(f, bytes.length, bytes.length));
      return f.url;
    } finally {
      client.close();
    }
  }

  @override
  Future<String> readText(ModelFile f) async => utf8.decode(await readBytes(f));

  @override
  Future<Uint8List> readBytes(ModelFile f) async {
    await ensure(f);
    return _bytes[f.url]!;
  }
}
