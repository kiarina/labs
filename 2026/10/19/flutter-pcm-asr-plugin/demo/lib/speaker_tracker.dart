import 'dart:typed_data';

import 'local/dsp/pcm.dart';

/// Quality-gated enrolment. Matching threshold is unchanged; uncertain short
/// evidence never creates or contaminates a persistent identity.
class SpeakerTracker {
  SpeakerTracker({this.refined = true});
  final bool refined;
  final List<List<Float32List>> speakers = [];
  final List<SpeakerObservation> observations = [];
  static const matchThreshold = .45, nearThreshold = .35;
  (int, double) best(Float32List vector) {
    var index = -1, score = -1.0;
    for (var i = 0; i < speakers.length; i++) {
      for (final v in speakers[i]) {
        final s = cosineSimilarity(vector, v);
        if (s > score) {
          score = s;
          index = i;
        }
      }
    }
    return (index, score);
  }

  SpeakerObservation observe(Float32List vector, double start, double end) {
    final (index, score) = best(vector);
    final duration = end - start;
    int? speaker;
    if (index >= 0 && score >= matchThreshold) {
      speaker = index;
      if (!refined || duration >= 1.5) {
        speakers[index].add(vector);
        if (speakers[index].length > 32) speakers[index].removeAt(0);
      }
    } else if (duration >= (refined ? 2.0 : 1.5) &&
        (!refined || index < 0 || score < nearThreshold || duration >= 3.0)) {
      speakers.add([vector]);
      speaker = speakers.length - 1;
    }
    final result = SpeakerObservation(vector, start, end, speaker, score);
    observations.add(result);
    if (observations.length > 256) observations.removeAt(0);
    if (refined) {
      for (final pending in observations.where((o) => o.speaker == null)) {
        final (candidate, similarity) = best(pending.vector);
        if (candidate >= 0 && similarity >= matchThreshold)
          pending.speaker = candidate;
      }
    }
    return result;
  }
}

class SpeakerObservation {
  SpeakerObservation(
    this.vector,
    this.start,
    this.end,
    this.speaker,
    this.score,
  );
  final Float32List vector;
  final double start, end, score;
  int? speaker;
}
