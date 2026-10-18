import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:audio_analysis/audio_analysis.dart';
import 'package:streaming_input_lab/pipeline.dart';
import 'package:streaming_input_lab/stream_types.dart';

class FixedVad implements OnnxModel {
  @override
  List<String> get inputNames => ['input'];
  @override
  List<String> get outputNames => ['output'];
  @override
  Future<Map<String, Tensor>> run(Map<String, Tensor> inputs) async => {
    'output': Tensor.float32(Float32List.fromList([0.9]), [1]),
  };
  @override
  Future<void> close() async {}
}

void main() {
  test(
    'PCM boundaries preserve samples, energy, VAD time and final voice',
    () async {
      final bytes = Uint8List(4096);
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < 2048; i++)
        view.setInt16(i * 2, i % 2 == 0 ? 16000 : -16000, Endian.little);
      final a = PcmAnalysis(FixedVad()), b = PcmAnalysis(FixedVad());
      await a.add(bytes);
      for (var i = 0; i < bytes.length; i += 319)
        await b.add(
          Uint8List.sublistView(bytes, i, (i + 319).clamp(0, bytes.length)),
        );
      a.finish();
      b.finish();
      expect(b.samples, 2048);
      expect(b.chunks, 4);
      expect(b.energy, a.energy);
      expect(b.voices, a.voices);
      expect(b.report()['dangling_byte'], false);
    },
  );
  test('empty input never invents a sample or voice', () async {
    final p = PcmAnalysis(FixedVad());
    await p.add(Uint8List(0));
    p.finish();
    expect(p.samples, 0);
    expect(p.voices, isEmpty);
  });

  test('long analysis retains a fixed recent voice window', () async {
    final p = PcmAnalysis(FixedVad());
    final b = Uint8List(32000);
    final v = ByteData.sublistView(b);
    for (var i = 0; i < 16000; i++) v.setInt16(i * 2, 12000, Endian.little);
    for (var i = 0; i < 120; i++) await p.add(b);
    p.finish();
    expect(p.samples, 120 * 16000);
    expect(p.voiceCount, greaterThan(8));
    expect(p.voices.length, lessThanOrEqualTo(8));
  });
  test('JPEG socket packets may split or coalesce frame markers', () {
    final p = JpegChunks(maxBytes: 20);
    expect(p.add(Uint8List.fromList([255])).toList(), isEmpty);
    expect(p.add(Uint8List.fromList([216, 1, 255])).toList(), isEmpty);
    final frames = p
        .add(Uint8List.fromList([217, 255, 216, 2, 255, 217]))
        .toList();
    expect(frames.length, 2);
    p.finish();
    expect(p.peakBytes, 5);
  });
  test('malformed image cannot grow a buffer without limit', () {
    final p = JpegChunks(maxBytes: 5);
    expect(
      () => p.add(Uint8List.fromList([255, 216, 1, 2, 3, 4])).toList(),
      throwsStateError,
    );
    final q = JpegChunks(maxBytes: 20);
    q.add(Uint8List.fromList([255, 216])).toList();
    expect(q.finish, throwsFormatException);
  });
}
