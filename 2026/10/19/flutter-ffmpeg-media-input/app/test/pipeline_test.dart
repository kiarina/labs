import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:audio_analysis/audio_analysis.dart';
import 'package:media_input_lab/pipeline.dart';

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
}
