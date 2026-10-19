import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:apple_speaker_lab/streaming_scd.dart';
import 'package:apple_speaker_lab/local/scd/speaker_change_detector.dart';

List<Speech> split(
  Float32List pcm,
  int rate,
  double base,
  List<double> cuts, {
  bool flip = false,
}) {
  final end = base + pcm.length / rate;
  final points = [base, ...cuts.where((t) => t > base && t < end), end];
  return [
    for (var i = 0; i + 1 < points.length; i++)
      Speech(
        samples: Float32List(0),
        sampleRate: rate,
        startTimestamp: points[i],
        endTimestamp: points[i + 1],
        speakerIndex: (i + (flip ? 1 : 0)) % 2,
      ),
  ];
}

Future<List<ConfirmedPart>> drive(StreamingScd s, int frames) async {
  final out = <ConfirmedPart>[];
  for (var i = 0; i < frames; i++) {
    out.addAll(
      await s.feed(
        Float32List.fromList(
          List.generate(4000, (j) => (i * 4000 + j) / 100000),
        ),
        i * .25,
        true,
      ),
    );
  }
  return out;
}

void main() {
  test('a transient within-window change does not commit audio', () async {
    var calls = 0;
    final s = StreamingScd(
      (pcm, r, t) async => split(pcm, r, t, ++calls == 3 ? [1.0] : []),
    );
    final out = await drive(s, 12);
    expect(out, isEmpty);
    expect(s.finish().single.speech.samples.length, 48000);
    expect(s.finish(), isEmpty);
  });
  test('stable boundaries survive local label permutation and never duplicate samples', () async {
    var calls = 0;
    final s = StreamingScd(
      (pcm, r, t) async => split(pcm, r, t, [1.0, 2.0], flip: ++calls % 2 == 0),
    );
    final out = await drive(s, 14);
    out.addAll(s.finish());
    expect(out.map((p) => p.reason).toList(), [
      'scd_change',
      'scd_change',
      'stop',
    ]);
    expect(out[0].speech.endTimestamp, 1);
    expect(out[1].speech.startTimestamp, 1);
    expect(out[1].speech.endTimestamp, 2);
    final all = out.expand((p) => p.speech.samples).toList();
    expect(all.length, 56000);
    for (var i = 0; i < all.length; i++) {
      expect(all[i], closeTo(i / 100000, .000001));
    }
  });
  test('VAD endpoint flushes remainder once after an early SCD cut', () async {
    final s = StreamingScd((pcm, r, t) async => split(pcm, r, t, [1.0]));
    final out = await drive(s, 8);
    out.addAll(await s.feed(Float32List(4000), 2, false, endpoint: 2.1));
    expect(out.map((p) => p.reason), ['scd_change', 'vad_end']);
    expect(out.last.speech.startTimestamp, 1);
    expect(out.last.speech.endTimestamp, 2.1);
    expect(s.finish(), isEmpty);
  });
  test('silence without VAD speech creates no ASR interval', () async {
    final s = StreamingScd(
      (pcm, r, t) async => throw StateError('should not infer'),
    );
    for (var i = 0; i < 8; i++) {
      expect(await s.feed(Float32List(4000), i * .25, false), isEmpty);
    }
    expect(s.finish(), isEmpty);
    expect(s.inferences, 0);
  });
  test('rolling past eight seconds preserves each audio sample once', () async {
    var calls = 0;
    final s = StreamingScd(
      (pcm, r, t) async =>
          split(pcm, r, t, [2, 5, 9, 12], flip: ++calls % 2 == 0),
    );
    final out = await drive(s, 56);
    out.addAll(s.finish());
    expect(out.map((p) => p.speech.endTimestamp).toList(), [2, 5, 9, 12, 14]);
    expect(out.fold<int>(0, (sum, p) => sum + p.speech.samples.length), 224000);
    for (var i = 0; i + 1 < out.length; i++) {
      expect(out[i].speech.endTimestamp, out[i + 1].speech.startTimestamp);
    }
    expect(s.audio.length, lessThanOrEqualTo(272000));
  });
}
