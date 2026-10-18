/// Interpolate measured waveform clock anchors; never fit against transcript text.
/// The uncertainty of lexical timestamps remains separate.
class AudioTimeMapping {
  AudioTimeMapping(this.start, this.end, this.extrapolated);
  final double start, end;
  final bool extrapolated;
}

AudioTimeMapping? mapAudioInterval(
  num start,
  num end,
  List<Map<String, dynamic>> anchors,
  num sessionMinusEchoMs, {
  double maxExtrapolationMs = 1000,
}) {
  if (anchors.length < 2) return null;
  final a = start - sessionMinusEchoMs, b = end - sessionMinusEchoMs;
  final sorted = [...anchors]
    ..sort((a, b) => (a['echo_ms'] as num).compareTo(b['echo_ms'] as num));
  final regions = <List<Map<String, dynamic>>>[];
  var current = <Map<String, dynamic>>[];
  for (final anchor in sorted) {
    if (current.isNotEmpty) {
      final prior = current.last;
      final delta = (anchor['echo_ms'] as num) - (prior['echo_ms'] as num);
      final slope = delta > 0
          ? ((anchor['device_ms'] as num) - (prior['device_ms'] as num)) / delta
          : 0;
      final jump =
          ((anchor['device_ms'] as num) -
                  (anchor['echo_ms'] as num) -
                  (prior['device_ms'] as num) +
                  (prior['echo_ms'] as num))
              .abs();
      if (delta > 4000 || slope < .9 || slope > 1.1 || jump > 100) {
        if (current.length >= 2) regions.add(current);
        current = [];
      }
    }
    current.add(anchor);
  }
  if (current.length >= 2) regions.add(current);
  List<Map<String, dynamic>>? selected;
  for (final region in regions) {
    final extraBefore = identical(region.first, sorted.first)
        ? maxExtrapolationMs
        : 0;
    final extraAfter = identical(region.last, sorted.last)
        ? maxExtrapolationMs
        : 0;
    if (a >= (region.first['echo_ms'] as num) - extraBefore &&
        b <= (region.last['echo_ms'] as num) + extraAfter) {
      selected = region;
      break;
    }
  }
  if (selected == null) return null;
  sorted.clear();
  sorted.addAll(selected);
  double at(num time) {
    if (time <= (sorted.first['echo_ms'] as num))
      return (time +
              (sorted.first['device_ms'] as num) -
              (sorted.first['echo_ms'] as num))
          .toDouble();
    if (time >= (sorted.last['echo_ms'] as num))
      return (time +
              (sorted.last['device_ms'] as num) -
              (sorted.last['echo_ms'] as num))
          .toDouble();
    for (var i = 1; i < sorted.length; i++) {
      final left = sorted[i - 1], right = sorted[i];
      final x = (left['echo_ms'] as num), y = (right['echo_ms'] as num);
      if (time <= y)
        return (left['device_ms'] as num) +
            (time - x) /
                (y - x) *
                ((right['device_ms'] as num) - (left['device_ms'] as num));
    }
    throw StateError('unreachable');
  }

  return AudioTimeMapping(
    at(a),
    at(b),
    a < (sorted.first['echo_ms'] as num) || b > (sorted.last['echo_ms'] as num),
  );
}

Set<String> speakerCandidates(
  double from,
  double to,
  List<Map<String, dynamic>> annotations, {
  double guardSeconds = 1,
}) {
  final candidates = <String>{};
  for (
    var t = (from - guardSeconds).clamp(0, double.infinity);
    t <= to + guardSeconds;
    t += .02
  ) {
    final matches = annotations
        .where(
          (a) =>
              a['speaker_id'] != null &&
              (a['start'] as num) <= t &&
              (a['end'] as num) >= t,
        )
        .toList();
    if (matches.isEmpty) continue;
    final newest = matches
        .map((a) => a['available_ms'] as int)
        .reduce((a, b) => a > b ? a : b);
    candidates.addAll(
      matches
          .where((a) => a['available_ms'] == newest)
          .map((a) => a['speaker_id'] as String),
    );
  }
  return candidates;
}
