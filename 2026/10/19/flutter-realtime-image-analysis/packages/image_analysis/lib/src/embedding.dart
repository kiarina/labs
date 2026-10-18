import 'dart:math' as math;
import 'dart:typed_data';

/// An embedding in the shape kiarina-agi-data's `Embedding` has
/// (`kind`, `space_id`, `vector`, `metadata`, `id`, `created_at`), so a
/// brain written with kiarina can store it in long-term memory as it is.
///
/// [spaceId] names the model space the way kiarina's providers do
/// (`sface:sha256=...:size=112:dim=128:norm=l2`); vectors from different
/// spaces must never be compared.
class Embedding {
  Embedding({
    required this.id,
    required this.kind,
    required this.spaceId,
    required this.vector,
    required this.createdAt,
    this.metadata = const {},
  });

  final String id;
  final String kind;
  final String spaceId;
  final Float32List vector;
  final DateTime createdAt;
  final Map<String, Object?> metadata;

  int get dimension => vector.length;

  /// kiarina's JSON field names. [decimals] rounds the vector (4 keeps
  /// cosine similarity within about 1e-4 and makes the JSON a quarter the size).
  Map<String, Object?> toJson({int? decimals}) => {
        'id': id,
        'created_at': createdAt.toUtc().toIso8601String(),
        'kind': kind,
        'space_id': spaceId,
        'vector': [for (final x in vector) decimals == null ? x : double.parse(x.toStringAsFixed(decimals))],
        'metadata': metadata,
      };
}

/// The space of one model, as kiarina's `EmbeddingSpace`.
class EmbeddingSpace {
  const EmbeddingSpace({required this.kind, required this.spaceId, required this.dimension});

  final String kind;
  final String spaceId;
  final int dimension;

  Map<String, Object?> toJson() => {'kind': kind, 'space_id': spaceId, 'dimension': dimension};
}

Float32List l2Normalize(Float32List v) {
  var s = 0.0;
  for (final x in v) {
    s += x * x;
  }
  final n = math.sqrt(s);
  if (n == 0) return v;
  return Float32List.fromList([for (final x in v) x / n]);
}

/// Cosine similarity of two L2-normalized vectors (a dot product).
double cosine(Float32List a, Float32List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

var _counter = 0;

/// Time-ordered, unique within the process; not a ULID, but sorts the same way.
String newEmbeddingId(DateTime at) =>
    '${at.microsecondsSinceEpoch.toRadixString(36).padLeft(11, '0')}${(_counter++ & 0xffff).toRadixString(36).padLeft(4, '0')}';
