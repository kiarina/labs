import 'dart:typed_data';

import '../dsp/pcm.dart';
import '../onnx.dart';

/// Port of kiarina's `EcapaTDNNOnnxAudioEmbeddingProvider`: 16 kHz waveform
/// in, 192-d L2-normalized speaker embedding out.
class EcapaSpeakerEmbedder {
  EcapaSpeakerEmbedder(
    this.model, {
    this.sampleRate = 16000,
    this.inputRank = 2,
  });

  final OnnxModel model;
  final int sampleRate;

  /// Rank of the waveform input ([1, N] = 2). Fixed per model because input
  /// metadata is unavailable on iOS, macOS and web.
  final int inputRank;

  Future<Float32List> embed(Float32List samples, int sourceRate) async {
    samples = resampleLinear(samples, sourceRate, sampleRate);
    final names = model.inputNames.toSet();
    final inputName = [
      'waveform',
      'waveforms',
      'input',
      'audio',
      'x',
    ].firstWhere(names.contains, orElse: () => model.inputNames.first);
    final shape = switch (inputRank) {
      3 => [1, 1, samples.length],
      2 => [1, samples.length],
      _ => [samples.length],
    };
    final inputs = {inputName: Tensor.float32(samples, shape)};
    if (names.contains('sample_rate')) {
      inputs['sample_rate'] = Tensor.int64([sampleRate], const []);
    }
    final outputs = await model.run(inputs);
    return l2Normalize(
      Float32List.fromList(outputs[model.outputNames.first]!.float32),
    );
  }
}
