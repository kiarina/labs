import 'dart:typed_data';

import '../tagging/yamnet.dart';

/// Something the analysis heard. JSON shape is what a body tool would return.
sealed class HearingEvent {
  HearingEvent(this.start, this.end) : createdAt = DateTime.now();

  /// Unix seconds of the first and last sample.
  final double start;
  final double end;
  final DateTime createdAt;

  String get kind;

  Map<String, Object?> toJson({bool embeddings = false});
}

class SpeechEvent extends HearingEvent {
  SpeechEvent({
    required double start,
    required double end,
    required this.speakerKind,
    required this.speaker,
    required this.text,
    required this.asrMs,
    this.embedding,
    this.language,
  }) : super(start, end);

  /// 'speaker' | 'unknown_silence' | 'unknown_overlap'
  final String speakerKind;

  /// Global speaker index within this session, null unless speakerKind == 'speaker'.
  final int? speaker;
  final String text;
  final String? language;
  final int asrMs;
  final Float32List? embedding;

  @override
  String get kind => 'speech';

  @override
  Map<String, Object?> toJson({bool embeddings = false}) => {
        'kind': kind,
        'start': start,
        'end': end,
        'speaker_kind': speakerKind,
        'speaker': speaker,
        'text': text,
        if (language != null) 'language': language,
        'asr_ms': asrMs,
        if (embeddings && embedding != null) 'embedding': embedding!.toList(),
      };
}

class AmbientEvent extends HearingEvent {
  AmbientEvent({
    required double start,
    required double end,
    required this.tags,
    this.embedding,
  }) : super(start, end);

  final List<TagPrediction> tags;
  final Float32List? embedding;

  @override
  String get kind => 'ambient';

  @override
  Map<String, Object?> toJson({bool embeddings = false}) => {
        'kind': kind,
        'start': start,
        'end': end,
        'tags': [for (final t in tags) t.toJson()],
        if (embeddings && embedding != null) 'embedding': embedding!.toList(),
      };
}
