import 'dart:typed_data';

import '../onnx.dart';

/// Silero VAD (ONNX). Port of kiarina's `SileroVADProvider`: keeps the
/// recurrent state and the last 64 samples (16 kHz) of context between calls.
class SileroVad {
  SileroVad(this.model);

  final OnnxModel model;

  static const supportedSampleRates = [8000, 16000];

  Float32List? _state;
  Float32List? _context;
  int? _lastSampleRate;

  void reset() {
    _state = null;
    _context = null;
    _lastSampleRate = null;
  }

  Future<double> predict(Float32List samples, int sampleRate) async {
    if (!supportedSampleRates.contains(sampleRate)) {
      throw ArgumentError(
        'Silero VAD supports $supportedSampleRates, got $sampleRate',
      );
    }
    if (_lastSampleRate != sampleRate) {
      _state = null;
      _context = null;
    }
    final contextSize = sampleRate == 16000 ? 64 : 32;
    _context ??= Float32List(contextSize);
    _lastSampleRate = sampleRate;

    final input = Float32List(contextSize + samples.length)
      ..setRange(0, contextSize, _context!)
      ..setRange(contextSize, contextSize + samples.length, samples);

    final names = model.inputNames.toSet();
    final audioName = [
      'input',
      'audio',
      'x',
    ].firstWhere(names.contains, orElse: () => model.inputNames.first);
    final inputs = <String, Tensor>{
      audioName: Tensor.float32(input, [1, input.length]),
    };
    if (names.contains('state')) {
      _state ??= Float32List(2 * 1 * 128);
      inputs['state'] = Tensor.float32(_state!, [2, 1, 128]);
    }
    if (names.contains('sr')) {
      inputs['sr'] = Tensor.int64([sampleRate], const []);
    }

    final outputs = await model.run(inputs);
    final stateName = model.outputNames.firstWhere(
      (n) => n.toLowerCase().startsWith('state'),
      orElse: () => model.outputNames.length > 1 ? model.outputNames[1] : '',
    );
    if (outputs[stateName] != null) {
      _state = Float32List.fromList(outputs[stateName]!.float32);
    }
    _context = Float32List.fromList(input.sublist(input.length - contextSize));
    return outputs[model.outputNames.first]!.float32[0];
  }
}
