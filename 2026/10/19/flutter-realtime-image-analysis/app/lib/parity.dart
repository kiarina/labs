import 'dart:math' as math;

import 'package:image_analysis/image_analysis.dart';

import 'engine.dart';

/// Runs the four models on every fixture frame and compares with the Python
/// ref path (same preprocessing, ONNX Runtime 1.31 on macOS arm64).
Future<Map<String, Object?>> runParity(Engine e, Fixtures fx, void Function(String) log) async {
  var faceCountDiff = 0, objectCountDiff = 0, labelDiff = 0;
  var maxFaceCoord = 0.0, maxFaceScore = 0.0, maxObjBox = 0.0, maxObjScore = 0.0;
  final faceCos = <double>[], objectCos = <double>[], sceneCos = <double>[];
  final ms = <String, List<double>>{'yunet': [], 'sface': [], 'dfine': [], 'siglip2_frame': [], 'siglip2_crop': []};
  final notes = <String>[];

  for (final f in fx.frames) {
    final name = f['name'] as String;
    final image = await fx.frame(name);

    // faces
    var sw = Stopwatch()..start();
    final faces = await e.yunet.detect(image);
    ms['yunet']!.add(sw.elapsedMicroseconds / 1000);
    final refFaces = (f['faces']['ref'] as List).cast<Map<String, dynamic>>();
    if (faces.length != refFaces.length) {
      faceCountDiff++;
      notes.add('$name faces ${faces.length} vs ${refFaces.length}');
    } else {
      for (var i = 0; i < faces.length; i++) {
        final r = refFaces[i];
        final a = [...faces[i].bbox, ...faces[i].keypoints.expand((k) => k)];
        final b = [...(r['bbox'] as List), ...(r['keypoints'] as List).expand((k) => k as List)].map((v) => (v as num).toDouble()).toList();
        for (var k = 0; k < a.length; k++) {
          maxFaceCoord = math.max(maxFaceCoord, (a[k] - b[k]).abs());
        }
        maxFaceScore = math.max(maxFaceScore, (faces[i].score - (r['score'] as num)).abs());
        sw = Stopwatch()..start();
        final v = await e.sface.embed(alignFacePixels(image, faces[i].keypointsPx));
        ms['sface']!.add(sw.elapsedMicroseconds / 1000);
        faceCos.add(cosine(v, await fx.embedding('$name.face$i')));
      }
    }

    // objects
    sw = Stopwatch()..start();
    final objects = await e.dfine.detect(image);
    ms['dfine']!.add(sw.elapsedMicroseconds / 1000);
    final refObjects = (f['objects']['ref'] as List).cast<Map<String, dynamic>>();
    if (objects.length != refObjects.length) {
      objectCountDiff++;
      notes.add('$name objects ${objects.length} vs ${refObjects.length}');
    } else {
      for (var i = 0; i < objects.length; i++) {
        final r = refObjects[i];
        if (objects[i].label != r['label']) labelDiff++;
        for (var k = 0; k < 4; k++) {
          maxObjBox = math.max(maxObjBox, (objects[i].bbox[k] - (r['bbox'][k] as num)).abs());
        }
        maxObjScore = math.max(maxObjScore, (objects[i].score - (r['score'] as num)).abs());
      }
    }
    // object crop embeddings: from the ref boxes, so the crops are the same
    final embs = (f['objects']['embeddings'] as List).cast<Map<String, dynamic>>();
    for (var rank = 0; rank < embs.length; rank++) {
      final bbox = [for (final v in refObjects[embs[rank]['index'] as int]['bbox'] as List) (v as num).toDouble()];
      sw = Stopwatch()..start();
      final v = await e.siglip.embed(image.cropNormalized(bbox));
      ms['siglip2_crop']!.add(sw.elapsedMicroseconds / 1000);
      objectCos.add(cosine(v, await fx.embedding('$name.object$rank')));
    }

    // scene
    sw = Stopwatch()..start();
    final scene = await e.siglip.embed(image);
    ms['siglip2_frame']!.add(sw.elapsedMicroseconds / 1000);
    sceneCos.add(cosine(scene, await fx.embedding('$name.scene')));
    log('parity $name');
  }

  Map<String, Object?> cosStats(List<double> v) => v.isEmpty
      ? {'n': 0}
      : {'n': v.length, 'min': v.reduce(math.min), 'median': (List.of(v)..sort())[v.length ~/ 2]};
  Map<String, Object?> msStats(List<double> v) {
    if (v.isEmpty) return {'n': 0};
    final s = List.of(v)..sort();
    return {'n': v.length, 'median': s[s.length ~/ 2], 'p90': s[(s.length * 0.9).floor().clamp(0, s.length - 1)], 'max': s.last};
  }

  return {
    'frames': fx.frames.length,
    'faces': {'frames_with_other_count': faceCountDiff, 'max_coord_diff': maxFaceCoord, 'max_score_diff': maxFaceScore, 'embedding_cos': cosStats(faceCos)},
    'objects': {'frames_with_other_count': objectCountDiff, 'label_diffs': labelDiff, 'max_bbox_diff': maxObjBox, 'max_score_diff': maxObjScore, 'crop_embedding_cos': cosStats(objectCos)},
    'scene_embedding_cos': cosStats(sceneCos),
    'model_ms': {for (final k in ms.keys) k: msStats(ms[k]!)},
    'notes': notes,
  };
}
