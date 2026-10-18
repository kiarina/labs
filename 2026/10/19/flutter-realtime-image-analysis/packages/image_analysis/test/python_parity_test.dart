// Preprocessing parity with the Python ref path (tools/make_fixtures.py):
// every tensor the Dart port feeds a model must have the same bytes. Model
// outputs need ONNX Runtime and are checked by the app (AUTO=parity).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_analysis/image_analysis.dart';

final _lab = Directory.current.parent.parent.path;

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

String _shaF32(Float32List v) => _sha(v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes));

RgbImage _frame(Map<String, dynamic> f) =>
    RgbImage(f['width'] as int, f['height'] as int, File('$_lab/work/frames/${f['name']}.rgb').readAsBytesSync());

void main() {
  final frames = (jsonDecode(File('$_lab/fixtures/frames.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();

  test('frames are the ones the fixtures were made from', () {
    for (final f in frames) {
      expect(_sha(_frame(f).data), f['rgb_sha256'], reason: f['name'] as String);
    }
  });

  test('YuNet input blob', () {
    for (final f in frames) {
      final img = _frame(f);
      expect(_shaF32(YuNet.blob(img)), f['faces']['blob_sha256'], reason: f['name'] as String);
    }
  });

  test('D-FINE input (OpenCV fixed-point resize to 640x640)', () {
    final d = DFine(_NoModel(), const []);
    for (final f in frames) {
      expect(_shaF32(d.input(_frame(f))), f['objects']['input_sha256'], reason: f['name'] as String);
    }
  });

  test('SigLIP2 input of whole frames and object crops', () {
    var crops = 0;
    for (final f in frames) {
      final img = _frame(f);
      expect(_shaF32(SigLip2.input(img)), f['scene']['input_sha256'], reason: '${f['name']} scene');
      final objects = (f['objects']['ref'] as List).cast<Map<String, dynamic>>();
      for (final e in (f['objects']['embeddings'] as List).cast<Map<String, dynamic>>()) {
        final bbox = [for (final v in objects[e['index'] as int]['bbox'] as List) (v as num).toDouble()];
        final crop = img.cropNormalized(bbox);
        expect(_sha(crop.data), e['crop_sha256'], reason: '${f['name']} crop ${e['index']}');
        expect(_shaF32(SigLip2.input(crop)), e['input_sha256'], reason: '${f['name']} crop ${e['index']} input');
        crops++;
      }
    }
    expect(crops, greaterThan(200));
  });

  test('aligned faces (Umeyama + bilinear warp)', () {
    var faces = 0, same = 0;
    final mismatched = <String>[];
    for (final f in frames) {
      final img = _frame(f);
      final dets = (f['faces']['ref'] as List).cast<Map<String, dynamic>>();
      final embs = (f['faces']['embeddings'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < dets.length; i++) {
        final kps = [for (final k in dets[i]['keypoints_px'] as List) [((k as List)[0] as num).toDouble(), (k[1] as num).toDouble()]];
        final aligned = alignFacePixels(img, kps);
        faces++;
        if (_sha(aligned.data) == embs[i]['aligned_sha256']) {
          same++;
        } else {
          mismatched.add('${f['name']}#$i');
        }
      }
    }
    // ignore: avoid_print
    print('aligned faces identical to the ref path: $same / $faces ${mismatched.isEmpty ? '' : mismatched}');
    expect(faces, greaterThan(20));
    expect(same, faces);
  });
}

class _NoModel implements OnnxModel {
  @override
  List<String> get inputNames => const [];
  @override
  List<String> get outputNames => const [];
  @override
  Future<Map<String, Tensor>> run(Map<String, Tensor> inputs, {Set<String>? outputs}) => throw UnimplementedError();
  @override
  Future<void> close() async {}
}
