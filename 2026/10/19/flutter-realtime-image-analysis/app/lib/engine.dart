import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:image_analysis/image_analysis.dart';

const ortThreads = int.fromEnvironment('ORT_THREADS', defaultValue: 0);

/// The four models, loaded once.
class Engine {
  Engine._(this.yunet, this.sface, this.dfine, this.siglip, this.loadMs, this.modelFiles);

  final YuNet yunet;
  final SFace sface;
  final DFine dfine;
  final SigLip2 siglip;
  final Map<String, double> loadMs;
  final Map<String, Object?> modelFiles;

  static Future<Engine> load({void Function(String)? log}) async {
    final store = ModelStore();
    final backend = FlutterOnnxBackend(threads: ortThreads > 0 ? ortThreads : null);
    final paths = <String, String>{};
    final files = <String, Object?>{};
    for (final f in ModelCatalog.all) {
      final sw = Stopwatch()..start();
      paths[f.filename] = await store.ensure(f, onProgress: (p) {
        if (!p.cached && (p.received == p.total || p.received % (16 << 20) < (1 << 20))) {
          log?.call('${f.id}/${f.filename} ${(p.fraction * 100).toStringAsFixed(0)}%');
        }
      });
      files['${f.id}/${f.filename}'] = {'sha256': f.sha256, 'bytes': f.bytes, 'ensure_ms': sw.elapsedMilliseconds};
    }
    final loadMs = <String, double>{};
    Future<OnnxModel> open(String name) async {
      final sw = Stopwatch()..start();
      final m = await backend.load(paths[name]!);
      loadMs[name] = sw.elapsedMicroseconds / 1000;
      return m;
    }

    final labels = DFine.labelsFromConfig(await File(paths['config.json']!).readAsString());
    return Engine._(
      YuNet(await open(ModelCatalog.yunet.filename)),
      SFace(await open(ModelCatalog.sface.filename), modelSha256: ModelCatalog.sface.sha256),
      DFine(await open(ModelCatalog.dfine.filename), labels),
      SigLip2(await open(ModelCatalog.siglip2.filename), modelSha256: ModelCatalog.siglip2.sha256),
      loadMs,
      files,
    );
  }

  SightAnalyzer analyzer({SightConfig config = const SightConfig()}) =>
      SightAnalyzer(yunet: yunet, sface: sface, dfine: dfine, siglip: siglip, config: config);
}

/// Fixtures and frames shipped in the app (made by `mise run prepare`).
class Fixtures {
  Fixtures._(this.input, this.frames);

  final Map<String, dynamic> input;
  final List<Map<String, dynamic>> frames;

  static Future<Fixtures> load() async => Fixtures._(
        jsonDecode(await rootBundle.loadString('assets/fixtures/input.json')) as Map<String, dynamic>,
        (jsonDecode(await rootBundle.loadString('assets/fixtures/frames.json')) as List).cast<Map<String, dynamic>>(),
      );

  Future<RgbImage> frame(String name) async {
    final data = (await rootBundle.load('assets/frames/$name.png')).buffer.asUint8List();
    final decoded = img.decodePng(data)!;
    final rgb = decoded.convert(format: img.Format.uint8, numChannels: 3);
    return RgbImage(rgb.width, rgb.height, Uint8List.fromList(rgb.getBytes(order: img.ChannelOrder.rgb)));
  }

  Future<Float32List> embedding(String name) async {
    final d = await rootBundle.load('assets/bin/$name.f32');
    return Float32List.fromList([for (var i = 0; i < d.lengthInBytes ~/ 4; i++) d.getFloat32(i * 4, Endian.little)]);
  }
}
