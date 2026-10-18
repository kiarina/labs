import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:image_analysis/image_analysis.dart';

import 'engine.dart';

final replayFps = double.parse(const String.fromEnvironment('FPS', defaultValue: '2'));
const replayLoops = int.fromEnvironment('LOOPS', defaultValue: 1);

/// Feeds the replay stream to a [SightAnalyzer] like a camera would.
///
/// [realtime]: frames arrive every 1 / [replayFps] s of wall time; a frame
/// that arrives while the previous one is still being analyzed waits, and
/// only the newest waiting frame is kept (the others are dropped and
/// counted). Otherwise every frame is analyzed back to back.
/// Timestamps given to the analyzer are stream time, so the result does not
/// depend on how fast the machine is (except for dropped frames).
Future<Map<String, Object?>> runReplay(Engine e, Fixtures fx, {required bool realtime, required void Function(String) log}) async {
  final stream = [for (final f in fx.frames) if (f['group'] == 'stream') f];
  final images = {for (final f in stream) f['name'] as String: await fx.frame(f['name'] as String)};
  final analyzer = e.analyzer();
  final start = DateTime.utc(2026, 10, 19, 12);
  final frameSeconds = 1 / replayFps;
  final perFrame = <Map<String, Object?>>[];
  final faceIdsBySegment = <String, Set<String>>{};
  final sceneBySegment = <String, Set<String>>{};
  final rssMb = <double>[];
  var dropped = 0;
  var analyzed = 0;
  final wall = Stopwatch()..start();
  final lagMs = <double>[];

  Future<void> analyzeOne(int loop, int index) async {
    final f = stream[index];
    final name = f['name'] as String;
    final streamT = loop * stream.length * frameSeconds + index * frameSeconds;
    final at = start.add(Duration(microseconds: (streamT * 1e6).round()));
    final t = await analyzer.analyze(images[name]!, at);
    analyzed++;
    final seg = f['segment'] as String;
    if (loop == 0) {
      faceIdsBySegment.putIfAbsent(seg, () => {}).addAll(analyzer.store.entities.values
          .where((x) => x.kind == 'face' && x.visible && x.lastSeen == at)
          .map((x) => x.id));
      sceneBySegment.putIfAbsent(seg, () => {}).add(analyzer.scene!.id);
    }
    perFrame.add({'loop': loop, 'frame': name, 'scene': analyzer.scene?.id, ...t.toJson()});
    if (analyzed % 13 == 0) rssMb.add(ProcessInfo.currentRss / (1 << 20));
  }

  for (var loop = 0; loop < replayLoops; loop++) {
    if (!realtime) {
      for (var i = 0; i < stream.length; i++) {
        await analyzeOne(loop, i);
      }
    } else {
      // camera: frame i arrives at loopStart + i / fps
      final loopStart = wall.elapsedMicroseconds / 1e6;
      var next = 0;
      while (next < stream.length) {
        final now = wall.elapsedMicroseconds / 1e6 - loopStart;
        final arrived = math.min(stream.length - 1, (now / frameSeconds).floor());
        if (arrived < next) {
          await Future<void>.delayed(Duration(microseconds: ((next * frameSeconds - now) * 1e6).ceil()));
          continue;
        }
        dropped += arrived - next; // older waiting frames are replaced by the newest
        lagMs.add((now - arrived * frameSeconds) * 1000);
        await analyzeOne(loop, arrived);
        next = arrived + 1;
      }
    }
    log('replay loop ${loop + 1}/$replayLoops: ${analyzer.store.entities.length} entities');
  }

  final store = analyzer.store;
  final entities = store.entities.values.toList();
  final byKind = <String, int>{};
  for (final x in entities) {
    byKind[x.kind] = (byKind[x.kind] ?? 0) + 1;
  }
  final face = entities.where((x) => x.kind == 'face').toList()..sort((a, b) => b.embeddings.length.compareTo(a.embeddings.length));

  Map<String, Object?> stage(String key) {
    final v = [for (final p in perFrame) (p[key] as num).toDouble()]..sort();
    final nonzero = v.where((x) => x > 0).toList();
    if (nonzero.isEmpty) return {'n': 0};
    return {
      'n': nonzero.length,
      'median': nonzero[nonzero.length ~/ 2],
      'p90': nonzero[(nonzero.length * 0.9).floor().clamp(0, nonzero.length - 1)],
      'max': nonzero.last,
    };
  }

  final a = faceIdsBySegment['dialogue_a'] ?? {};
  final b = faceIdsBySegment['dialogue_b'] ?? {};
  return {
    'realtime': realtime,
    'fps': replayFps,
    'loops': replayLoops,
    'stream_frames': stream.length * replayLoops,
    'analyzed': analyzed,
    'dropped': dropped,
    'wall_s': wall.elapsedMilliseconds / 1000,
    'stream_s': stream.length * replayLoops * frameSeconds,
    if (lagMs.isNotEmpty) 'lag_ms': {'median': (List.of(lagMs)..sort())[lagMs.length ~/ 2], 'max': lagMs.reduce(math.max)},
    'stage_ms': {for (final k in ['total_ms', 'scene_ms', 'faces_ms', 'face_embed_ms', 'objects_ms', 'object_embed_ms']) k: stage(k)},
    'entities': byKind,
    'events': store.events.length,
    'embeddings': {'count': entities.fold<int>(0, (s, x) => s + x.embeddings.length), 'bytes': store.embeddingBytes},
    'rss_mb': rssMb,
    'checks': {
      'faces_in_dialogue_a': a.toList()..sort(),
      'faces_in_dialogue_b': b.toList()..sort(),
      'face_came_back_as_same_entity': b.isNotEmpty && b.every(a.contains),
      'scenes_by_segment': {for (final e in sceneBySegment.entries) e.key: e.value.toList()..sort()},
      'dialogue_scene_came_back': (sceneBySegment['dialogue_b'] ?? {}).every((s) => (sceneBySegment['dialogue_a'] ?? {}).contains(s)),
    },
    'entity_list': [for (final x in entities) x.toJson()],
    'event_list': [for (final ev in store.events) ev.toJson()],
    'frames': perFrame,
    if (face.isNotEmpty) 'example_face_entity': face.first.toJson(withEmbeddings: true),
  };
}
