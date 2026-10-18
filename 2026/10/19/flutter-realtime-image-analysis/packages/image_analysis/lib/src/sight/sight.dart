import 'dart:math' as math;
import 'dart:typed_data';

import '../embedding.dart';
import '../image/align.dart';
import '../image/resize.dart';
import '../image/rgb_image.dart';
import '../models/detectors.dart';
import '../models/embedders.dart';

/// Thresholds and pacing of [SightAnalyzer]. The defaults come from the
/// lab's replay stream (tools/similarity_report.py, README "Thresholds").
class SightConfig {
  const SightConfig({
    this.faceMatch = 0.363,
    this.faceReturn = 0.5,
    this.maxFaces = 8,
    this.objectInterval = const Duration(seconds: 1),
    this.maxObjectEmbeddings = 8,
    this.minObjectSide = 24,
    this.objectIou = 0.3,
    this.objectReidentify = 0.95,
    this.objectRefresh = const Duration(seconds: 10),
    this.sceneChange = 0.85,
    this.sceneMatch = 0.90,
    this.goneAfter = const Duration(seconds: 2),
    this.keepFaceEmbeddings = 16,
    this.keepObjectEmbeddings = 4,
    this.keepSceneEmbeddings = 8,
    this.novelty = 0.95,
    this.thumbnailSide = 128,
  });

  /// SFace cosine at or above which a face is the same person (OpenCV's
  /// documented threshold for SFace; the lab's same-person pairs were all
  /// above it when compared with a track's best embedding).
  final double faceMatch;

  /// A face matches a person who had left only at this similarity: in the
  /// lab, strangers reached 0.374 against a kept track and the person who
  /// came back at least 0.701.
  final double faceReturn;
  final int maxFaces;

  /// Objects are detected at most this often (and on every scene change).
  final Duration objectInterval;

  /// Crops embedded per object pass (new tracks first, then stale ones).
  final int maxObjectEmbeddings;
  final int minObjectSide;

  /// An object continues a visible track of the same label when the boxes
  /// overlap at least this much.
  final double objectIou;

  /// A new box of a label can re-identify a gone object of the same label
  /// only at this SigLIP2 similarity (same-label different objects reach
  /// 0.94 in the lab, so this is a hint, not an identity).
  final double objectReidentify;
  final Duration objectRefresh;

  /// SigLIP2 similarity of a frame to the current scene below which the
  /// scene changed; [sceneMatch] for recognizing a scene seen before.
  final double sceneChange;
  final double sceneMatch;

  /// An entity not seen for this long has left (one event).
  final Duration goneAfter;

  final int keepFaceEmbeddings;
  final int keepObjectEmbeddings;
  final int keepSceneEmbeddings;

  /// A new embedding is kept for an entity only if it is less similar than
  /// this to all it keeps (keeps the set varied: poses, light).
  final double novelty;
  final int thumbnailSide;
}

/// Something seen: a person's face (`f1`...), an object (`o1`...) or a
/// scene, i.e. a place/view (`s1`...). Ids are for this analyzer's lifetime
/// only; who or what an entity is, is for the brain (and its long-term
/// memory) to decide, using [embeddings].
class SightEntity {
  SightEntity({required this.id, required this.kind, required this.label, required this.firstSeen})
      : lastSeen = firstSeen;

  final String id;
  final String kind;
  String label;
  final DateTime firstSeen;
  DateTime lastSeen;
  int sightings = 0;
  bool visible = true;
  List<double>? bbox;
  double bestScore = 0;

  /// Small RGB crop of the best sighting (faces: the aligned face).
  RgbImage? thumbnail;

  final List<Embedding> embeddings = [];
  DateTime? lastEmbedded;

  double bestSimilarity(Float32List v) {
    var best = -1.0;
    for (final e in embeddings) {
      best = math.max(best, cosine(e.vector, v));
    }
    return best;
  }

  Map<String, Object?> toJson({bool withEmbeddings = false, int? decimals = 4}) => {
        'id': id,
        'kind': kind,
        'label': label,
        'first_seen': firstSeen.toUtc().toIso8601String(),
        'last_seen': lastSeen.toUtc().toIso8601String(),
        'sightings': sightings,
        'visible': visible,
        if (bbox != null) 'bbox': [for (final v in bbox!) double.parse(v.toStringAsFixed(4))],
        'embedding_count': embeddings.length,
        if (withEmbeddings) 'embeddings': [for (final e in embeddings) e.toJson(decimals: decimals)],
      };
}

/// What happened: an entity appeared (or came back), left, or the scene
/// changed.
class SightEvent {
  SightEvent(this.kind, this.at, this.entity, {this.similarity, this.returned = false, this.bbox, this.from});

  /// `appeared`, `left`, `scene`.
  final String kind;
  final DateTime at;
  final SightEntity entity;
  final double? similarity;

  /// The entity had been seen before and left (re-identified).
  final bool returned;
  final List<double>? bbox;

  /// For `scene`: the scene before.
  final SightEntity? from;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'at': at.toUtc().toIso8601String(),
        'entity': entity.id,
        'entity_kind': entity.kind,
        'label': entity.label,
        if (returned) 'returned': true,
        if (similarity != null) 'similarity': double.parse(similarity!.toStringAsFixed(3)),
        if (bbox != null) 'bbox': [for (final v in bbox!) double.parse(v.toStringAsFixed(4))],
        if (from != null) 'from': from!.id,
      };
}

/// Per-stage time of one frame, in milliseconds.
class SightTimings {
  double faces = 0, faceEmbed = 0, objects = 0, objectEmbed = 0, scene = 0, total = 0;
  int faceCount = 0, objectCount = 0, objectEmbedCount = 0;
  bool objectPass = false;

  Map<String, Object?> toJson() => {
        'faces_ms': _r(faces),
        'face_embed_ms': _r(faceEmbed),
        'objects_ms': _r(objects),
        'object_embed_ms': _r(objectEmbed),
        'scene_ms': _r(scene),
        'total_ms': _r(total),
        'faces': faceCount,
        'objects': objectCount,
        'object_embeds': objectEmbedCount,
        'object_pass': objectPass,
      };

  static double _r(double v) => double.parse(v.toStringAsFixed(2));
}

/// Analyzes camera frames into entities and events, keeping embeddings.
///
/// Per frame: faces (YuNet, then SFace on each aligned face) and the whole
/// frame (SigLIP2) every time; objects (D-FINE, then SigLIP2 on the crops
/// of new or stale tracks) every [SightConfig.objectInterval] and on every
/// scene change.
class SightAnalyzer {
  SightAnalyzer({required this.yunet, required this.sface, required this.dfine, required this.siglip, this.config = const SightConfig()});

  final YuNet yunet;
  final SFace sface;
  final DFine dfine;
  final SigLip2 siglip;
  final SightConfig config;

  final store = SightStore();
  SightEntity? scene;
  DateTime? _lastObjectPass;
  final _counters = <String, int>{};

  String _nextId(String prefix) {
    final n = (_counters[prefix] ?? 0) + 1;
    _counters[prefix] = n;
    return '$prefix$n';
  }

  Embedding _embedding(EmbeddingSpace space, Float32List v, DateTime at, Map<String, Object?> meta) =>
      Embedding(id: newEmbeddingId(at), kind: space.kind, spaceId: space.spaceId, vector: v, createdAt: at, metadata: meta);

  void _keep(SightEntity e, Embedding emb, int cap) {
    e.lastEmbedded = emb.createdAt;
    if (e.embeddings.isNotEmpty && e.bestSimilarity(emb.vector) >= config.novelty) return;
    e.embeddings.add(emb);
    // keep the first (the original look) and the most recent ones
    while (e.embeddings.length > cap) {
      e.embeddings.removeAt(1);
    }
  }

  RgbImage _thumb(RgbImage crop) {
    final side = math.max(crop.width, crop.height);
    if (side <= config.thumbnailSide || crop.width == 0 || crop.height == 0) return crop;
    final s = config.thumbnailSide / side;
    return resizeLinear(crop, math.max(1, (crop.width * s).round()), math.max(1, (crop.height * s).round()));
  }

  Future<SightTimings> analyze(RgbImage frame, DateTime at) async {
    final t = SightTimings();
    final total = Stopwatch()..start();
    final seen = <SightEntity>{};

    // ---- scene
    var sw = Stopwatch()..start();
    final sceneVec = await siglip.embed(frame);
    t.scene = sw.elapsedMicroseconds / 1000;
    final sceneChanged = _updateScene(sceneVec, frame, at);

    // ---- faces
    sw = Stopwatch()..start();
    final faces = (await yunet.detect(frame)).take(config.maxFaces).toList();
    t.faces = sw.elapsedMicroseconds / 1000;
    t.faceCount = faces.length;
    sw = Stopwatch()..start();
    final claimed = <SightEntity>{};
    for (final f in faces) {
      final aligned = alignFacePixels(frame, f.keypointsPx);
      final v = await sface.embed(aligned);
      SightEntity? best;
      var bestSim = -1.0;
      for (final e in store.entities.values) {
        if (e.kind != 'face' || claimed.contains(e)) continue;
        final s = e.bestSimilarity(v);
        if (s >= (e.visible ? config.faceMatch : config.faceReturn) && s > bestSim) {
          bestSim = s;
          best = e;
        }
      }
      final isNew = best == null;
      final entity = best ?? store.add(SightEntity(id: _nextId('f'), kind: 'face', label: 'face', firstSeen: at));
      claimed.add(entity);
      final returned = !isNew && !entity.visible;
      if (isNew || returned) {
        store.event(SightEvent('appeared', at, entity, returned: returned, similarity: isNew ? null : bestSim, bbox: f.bbox));
      }
      _sighted(entity, at, f.bbox, f.score, aligned);
      _keep(entity, _embedding(sface.space, v, at, {'bbox': f.bbox, 'score': f.score, 'width': frame.width, 'height': frame.height}), config.keepFaceEmbeddings);
      seen.add(entity);
    }
    t.faceEmbed = sw.elapsedMicroseconds / 1000;

    // ---- objects
    final due = _lastObjectPass == null || at.difference(_lastObjectPass!) >= config.objectInterval || sceneChanged;
    if (due) {
      t.objectPass = true;
      _lastObjectPass = at;
      sw = Stopwatch()..start();
      final dets = await dfine.detect(frame);
      t.objects = sw.elapsedMicroseconds / 1000;
      t.objectCount = dets.length;
      sw = Stopwatch()..start();
      await _updateObjects(dets, frame, at, seen, t);
      t.objectEmbed = sw.elapsedMicroseconds / 1000;
    } else {
      // objects not looked at this frame stay as they were
      for (final e in store.entities.values) {
        if (e.kind == 'object' && e.visible) seen.add(e);
      }
    }

    // ---- who left
    for (final e in store.entities.values) {
      if (e.kind == 'scene' || !e.visible || seen.contains(e)) continue;
      if (at.difference(e.lastSeen) >= config.goneAfter) {
        e.visible = false;
        store.event(SightEvent('left', at, e));
      }
    }
    store.prune(at);
    t.total = total.elapsedMicroseconds / 1000;
    return t;
  }

  bool _updateScene(Float32List v, RgbImage frame, DateTime at) {
    final current = scene;
    if (current != null && current.bestSimilarity(v) >= config.sceneChange) {
      current.lastSeen = at;
      current.sightings++;
      _keep(current, _embedding(siglip.space('scene'), v, at, {'width': frame.width, 'height': frame.height}), config.keepSceneEmbeddings);
      return false;
    }
    SightEntity? best;
    var bestSim = config.sceneMatch;
    for (final e in store.entities.values) {
      if (e.kind != 'scene' || e == current) continue;
      final s = e.bestSimilarity(v);
      if (s >= bestSim) {
        bestSim = s;
        best = e;
      }
    }
    final isNew = best == null;
    final next = best ?? store.add(SightEntity(id: _nextId('s'), kind: 'scene', label: 'scene', firstSeen: at));
    current?.visible = false;
    next.visible = true;
    next.lastSeen = at;
    next.sightings++;
    if (next.thumbnail == null) next.thumbnail = _thumb(frame);
    _keep(next, _embedding(siglip.space('scene'), v, at, {'width': frame.width, 'height': frame.height}), config.keepSceneEmbeddings);
    store.event(SightEvent('scene', at, next, from: current, returned: !isNew, similarity: isNew ? null : bestSim));
    scene = next;
    return current != null;
  }

  Future<void> _updateObjects(List<Detection> dets, RgbImage frame, DateTime at, Set<SightEntity> seen, SightTimings t) async {
    final visible = [for (final e in store.entities.values) if (e.kind == 'object' && e.visible) e];
    final claimed = <SightEntity>{};
    final fresh = <(Detection, SightEntity, bool)>[]; // det, entity, isNew
    // greedy: highest score first, best IoU with a visible track of the same label
    final order = [...dets]..sort((a, b) => b.score.compareTo(a.score));
    for (final d in order) {
      SightEntity? best;
      var bestIou = config.objectIou;
      for (final e in visible) {
        if (claimed.contains(e) || e.label != d.label || e.bbox == null) continue;
        final iou = _iou(e.bbox!, d.bbox);
        if (iou >= bestIou) {
          bestIou = iou;
          best = e;
        }
      }
      if (best != null) {
        claimed.add(best);
        _sighted(best, at, d.bbox, d.score, null);
        seen.add(best);
        fresh.add((d, best, false));
      } else {
        fresh.add((d, SightEntity(id: '', kind: 'object', label: d.label, firstSeen: at), true));
      }
    }
    // embed crops: new boxes first, then tracks whose embedding is stale
    var budget = config.maxObjectEmbeddings;
    final queue = [
      ...fresh.where((x) => x.$3),
      ...fresh.where((x) => !x.$3 && (x.$2.lastEmbedded == null || at.difference(x.$2.lastEmbedded!) >= config.objectRefresh)),
    ];
    for (final (d, e, isNew) in queue) {
      final crop = frame.cropNormalized(d.bbox);
      final big = crop.width >= config.minObjectSide && crop.height >= config.minObjectSide;
      Float32List? v;
      if (big && budget > 0) {
        budget--;
        v = await siglip.embed(crop);
        t.objectEmbedCount++;
      }
      var entity = e;
      if (isNew) {
        if (!big) continue; // too small to keep as an entity
        // re-identify a gone object of the same label (a hint, see config)
        SightEntity? back;
        var backSim = config.objectReidentify;
        if (v != null) {
          for (final g in store.entities.values) {
            if (g.kind != 'object' || g.visible || g.label != d.label || claimed.contains(g)) continue;
            final s = g.bestSimilarity(v);
            if (s >= backSim) {
              backSim = s;
              back = g;
            }
          }
        }
        entity = back ?? store.add(SightEntity(id: _nextId('o'), kind: 'object', label: d.label, firstSeen: at));
        claimed.add(entity);
        store.event(SightEvent('appeared', at, entity, returned: back != null, similarity: back != null ? backSim : null, bbox: d.bbox));
        _sighted(entity, at, d.bbox, d.score, crop);
        seen.add(entity);
      } else if (d.score >= entity.bestScore && big) {
        entity.thumbnail = _thumb(crop);
      }
      if (v != null) {
        _keep(entity, _embedding(siglip.space('object'), v, at, {'bbox': d.bbox, 'score': d.score, 'label': d.label}), config.keepObjectEmbeddings);
      }
    }
  }

  void _sighted(SightEntity e, DateTime at, List<double> bbox, double score, RgbImage? crop) {
    e.visible = true;
    e.lastSeen = at;
    e.sightings++;
    e.bbox = bbox;
    if (crop != null && (e.thumbnail == null || score > e.bestScore)) e.thumbnail = _thumb(crop);
    e.bestScore = math.max(e.bestScore, score);
  }

  static double _iou(List<double> a, List<double> b) {
    final iw = math.min(a[2], b[2]) - math.max(a[0], b[0]);
    final ih = math.min(a[3], b[3]) - math.max(a[1], b[1]);
    final inter = math.max(iw, 0.0) * math.max(ih, 0.0);
    final union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter;
    return union > 0 ? inter / union : 0;
  }
}

/// Entities and events, bounded: events by age and count, entities not
/// seen for [retention] are forgotten (a brain that wants to remember one
/// stores its embeddings before then).
class SightStore {
  SightStore({this.retention = const Duration(hours: 1), this.maxEvents = 5000, this.maxEntities = 500});

  final Duration retention;
  final int maxEvents;
  final int maxEntities;
  final entities = <String, SightEntity>{};
  final events = <SightEvent>[];

  SightEntity add(SightEntity e) => entities[e.id] = e;

  void event(SightEvent e) {
    events.add(e);
    while (events.length > maxEvents) {
      events.removeAt(0);
    }
  }

  void prune(DateTime now) {
    final cutoff = now.subtract(retention);
    events.removeWhere((e) => e.at.isBefore(cutoff));
    entities.removeWhere((_, e) => !e.visible && e.lastSeen.isBefore(cutoff));
    if (entities.length > maxEntities) {
      final gone = entities.values.where((e) => !e.visible).toList()..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
      for (final e in gone.take(entities.length - maxEntities)) {
        entities.remove(e.id);
      }
    }
  }

  /// What a brain tool would call: events since [since], newest last.
  List<SightEvent> query({DateTime? since, Set<String>? kinds, int limit = 100}) {
    final m = events.where((e) => (since == null || !e.at.isBefore(since)) && (kinds == null || kinds.contains(e.entity.kind))).toList();
    return m.length <= limit ? m : m.sublist(m.length - limit);
  }

  /// Bytes the kept embeddings take (vectors only).
  int get embeddingBytes => entities.values.fold(0, (s, e) => s + e.embeddings.fold(0, (t, x) => t + x.vector.lengthInBytes));
}
