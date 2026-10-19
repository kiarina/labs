import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pcm.dart';
import 'pyannote_scd.dart';

const unknownSilence = -1;
const unknownOverlap = -2;

class Speech {
  Speech({
    required this.samples,
    required this.sampleRate,
    required this.startTimestamp,
    required this.endTimestamp,
    required this.speakerIndex,
  });

  final Float32List samples;
  final int sampleRate;
  final double startTimestamp;
  final double endTimestamp;

  /// Local index from the change detector (-1 silence, -2 overlap); replaced
  /// by the global speaker index after embedding.
  int speakerIndex;

  String get kind => switch (speakerIndex) {
        unknownSilence => 'unknown_silence',
        unknownOverlap => 'unknown_overlap',
        _ => 'speaker',
      };
}

class SpeakerChangeDetectorSettings {
  const SpeakerChangeDetectorSettings({
    this.threshold = 0.5,
    this.overlapMargin = 0.1,
    this.minChangeMs = 100,
    this.minSpeechMs = 100,
  });

  final double threshold;
  final double overlapMargin;
  final int minChangeMs;
  final int minSpeechMs;
}

class _Run {
  _Run(this.label, this.start, this.end);

  final int label;
  final int start;
  final int end;

  int get count => end - start;
}

/// Port of kiarina's `SpeakerChangeDetector`.
class SpeakerChangeDetector {
  SpeakerChangeDetector(this.scd, {this.settings = const SpeakerChangeDetectorSettings()});

  final ScdPredictor scd;
  final SpeakerChangeDetectorSettings settings;

  Future<List<Speech>> detect(Float32List samples, int sampleRate, double timestamp) async {
    if (samples.isEmpty) return [];
    final result = await scd.predict(samples, sampleRate);
    if (result.frames == 0) {
      return [_speech(samples, sampleRate, timestamp, 0, samples.length, unknownSilence)];
    }
    var labels = _frameLabels(result);
    labels = _mergeSilence(labels);
    var runs = _runs(labels);
    runs = _smooth(runs, _msToFrames(settings.minChangeMs, result.frameMs));
    runs = _smooth(runs, _msToFrames(settings.minSpeechMs, result.frameMs));
    return [
      for (final run in runs)
        _speech(
          samples,
          sampleRate,
          timestamp,
          _frameToSample(run.start, sampleRate, result.frameMs),
          run.end >= labels.length ? samples.length : _frameToSample(run.end, sampleRate, result.frameMs),
          run.label,
        ),
    ];
  }

  List<int> _frameLabels(ScdResult r) {
    final labels = <int>[];
    for (var f = 0; f < r.frames; f++) {
      final frame = r.frame(f);
      final active = [for (var i = 0; i < frame.length; i++) if (frame[i] >= settings.threshold) i];
      if (active.isEmpty) {
        labels.add(unknownSilence);
        continue;
      }
      // np.argsort(frame)[::-1]: stable ascending sort reversed -> ties prefer the higher index.
      final order = List<int>.generate(frame.length, (i) => i)
        ..sort((a, b) {
          final c = frame[a].compareTo(frame[b]);
          return c != 0 ? c : a.compareTo(b);
        });
      final top = order.last;
      if (active.length >= 2) {
        final second = order[order.length - 2];
        // Python computes this margin in float32.
        final margin = Float32List.fromList([frame[top] - frame[second]])[0];
        if (margin <= settings.overlapMargin) {
          labels.add(unknownOverlap);
          continue;
        }
      }
      labels.add(top);
    }
    return labels;
  }

  List<int> _mergeSilence(List<int> labels) {
    if (labels.every((l) => l == unknownSilence)) return labels;
    final merged = [...labels];
    var index = 0;
    while (index < merged.length) {
      if (merged[index] != unknownSilence) {
        index++;
        continue;
      }
      final start = index;
      while (index < merged.length && merged[index] == unknownSilence) {
        index++;
      }
      final end = index;
      final prev = start > 0 ? merged[start - 1] : null;
      final next = end < merged.length ? merged[end] : null;
      if (prev == null && next == null) continue;
      final int fill;
      if (prev == null) {
        fill = start;
      } else if (next == null || prev == next) {
        fill = end;
      } else {
        fill = start + (end - start) ~/ 2;
      }
      for (var i = start; i < end; i++) {
        if (i < fill && prev != null) {
          merged[i] = prev;
        } else if (next != null) {
          merged[i] = next;
        } else if (prev != null) {
          merged[i] = prev;
        }
      }
    }
    return merged;
  }

  List<_Run> _runs(List<int> labels) {
    if (labels.isEmpty) return [];
    final runs = <_Run>[];
    var start = 0;
    var current = labels[0];
    for (var i = 1; i < labels.length; i++) {
      if (labels[i] == current) continue;
      runs.add(_Run(current, start, i));
      start = i;
      current = labels[i];
    }
    runs.add(_Run(current, start, labels.length));
    return runs;
  }

  List<_Run> _smooth(List<_Run> runs, int minFrames) {
    if (minFrames <= 1 || runs.length <= 1) return runs;
    final labels = [for (final r in runs) for (var i = 0; i < r.count; i++) r.label];
    for (var i = 0; i < runs.length; i++) {
      final run = runs[i];
      if (run.count >= minFrames) continue;
      final prev = i > 0 ? runs[i - 1] : null;
      final next = i + 1 < runs.length ? runs[i + 1] : null;
      final int replacement;
      if (prev != null && next != null) {
        if (prev.label == next.label) {
          replacement = prev.label;
        } else if (prev.count >= next.count) {
          replacement = prev.label;
        } else {
          replacement = next.label;
        }
      } else if (prev != null) {
        replacement = prev.label;
      } else if (next != null) {
        replacement = next.label;
      } else {
        replacement = run.label;
      }
      for (var f = run.start; f < run.end; f++) {
        labels[f] = replacement;
      }
    }
    return _runs(labels);
  }

  Speech _speech(Float32List samples, int sampleRate, double timestamp, int start, int end, int speaker) {
    start = start.clamp(0, samples.length);
    end = end.clamp(start, samples.length);
    return Speech(
      samples: Float32List.sublistView(samples, start, end),
      sampleRate: sampleRate,
      startTimestamp: timestamp + start / sampleRate,
      endTimestamp: timestamp + end / sampleRate,
      speakerIndex: speaker,
    );
  }

  int _frameToSample(int frame, int sampleRate, double frameMs) => pyRound(frame * frameMs * sampleRate / 1000);

  int _msToFrames(int ms, double frameMs) => math.max(1, pyRound(ms / frameMs));
}
