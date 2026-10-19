import 'dart:math';
import 'dart:typed_data';

import 'local/dsp/pcm.dart';
import 'local/scd/speaker_change_detector.dart';

typedef DetectParts = Future<List<Speech>> Function(Float32List, int, double);

class ConfirmedPart {
  ConfirmedPart(this.speech, this.reason, this.confirmedAt);
  final Speech speech;
  final String reason;
  final double confirmedAt;
}

/// Uses positions of within-window transitions. Local pyannote speaker indices
/// are never treated as persistent identities across rolling-window calls.
class StreamingScd {
  StreamingScd(
    this.detect, {
    this.hop = .25,
    this.lookahead = .35,
    this.votes = 2,
  });
  final DetectParts detect;
  final double hop, lookahead;
  final int votes;
  Float32List audio = Float32List(0);
  int base = 0, received = 0, committed = 0, nextCheck = 0;
  int? start;
  double? candidate;
  int confirmations = 0;
  int inferences = 0;
  final inferenceMs = <double>[];
  Future<List<ConfirmedPart>> feed(
    Float32List frame,
    double timestamp,
    bool voiced, {
    double? endpoint,
  }) async {
    final from = (timestamp * 16000).round();
    if (audio.isEmpty) {
      base = from;
      received = from;
    }
    if (from != received) throw StateError('non_contiguous_input');
    audio = concatFloat32([audio, frame]);
    received += frame.length;
    if (start == null && voiced) {
      start = max(committed, max(base, from - 3200));
      candidate = null;
      confirmations = 0;
      nextCheck = received;
    }
    final out = <ConfirmedPart>[];
    if (start != null && received >= nextCheck && received - start! >= 16000) {
      nextCheck = received + (hop * 16000).round();
      final window = max(base, received - 128000);
      final watch = Stopwatch()..start();
      final parts = await detect(
        Float32List.sublistView(audio, window - base),
        16000,
        window / 16000,
      );
      inferences++;
      inferenceMs.add(watch.elapsedMicroseconds / 1000);
      if (inferenceMs.length > 256) inferenceMs.removeAt(0);
      double? boundary;
      for (var i = 0; i + 1 < parts.length; i++) {
        final left = parts[i], right = parts[i + 1];
        final at = left.endTimestamp;
        if (left.kind == 'speaker' &&
            right.kind == 'speaker' &&
            left.speakerIndex != right.speakerIndex &&
            at >= start! / 16000 + .5 &&
            at <= received / 16000 - lookahead &&
            right.endTimestamp - right.startTimestamp >= .2) {
          boundary = at;
          break;
        }
      }
      if (boundary == null) {
        candidate = null;
        confirmations = 0;
      } else {
        if (candidate != null && (candidate! - boundary).abs() <= .15) {
          confirmations++;
        } else {
          confirmations = 1;
        }
        candidate = boundary;
        if (confirmations >= votes) {
          final cut = (boundary * 16000).round();
          out.add(emit(cut, 'scd_change'));
          start = cut;
          candidate = null;
          confirmations = 0;
        }
      }
    }
    if (endpoint != null && start != null) {
      final end = min(received, (endpoint * 16000).round());
      if (end > start!) out.add(emit(end, voiced ? 'safety_limit' : 'vad_end'));
      start = null;
      candidate = null;
      confirmations = 0;
    }
    // Current uncommitted audio is bounded by the VAD's 15-second safety cap.
    final keep = start == null
        ? max(base, received - 128000)
        : max(base, min(start!, received - 128000));
    if (keep > base) {
      audio = Float32List.fromList(audio.sublist(keep - base));
      base = keep;
    }
    if (audio.length > 272000) throw StateError('stream_audio_limit');
    return out;
  }

  ConfirmedPart emit(int end, String reason) {
    final from = start!;
    final pcm = Float32List.fromList(audio.sublist(from - base, end - base));
    committed = end;
    return ConfirmedPart(
      Speech(
        samples: pcm,
        sampleRate: 16000,
        startTimestamp: from / 16000,
        endTimestamp: end / 16000,
        speakerIndex: 0,
      ),
      reason,
      received / 16000,
    );
  }

  List<ConfirmedPart> finish() {
    if (start == null || received <= start!) return [];
    final part = emit(received, 'stop');
    start = null;
    candidate = null;
    confirmations = 0;
    return [part];
  }
}
