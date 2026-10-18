import 'dart:typed_data';

class AsrResult {
  AsrResult(this.text, {this.language, this.elapsed = Duration.zero});

  final String text;
  final String? language;
  final Duration elapsed;
}

/// Speech-to-text for one utterance. The local default is whisper.cpp
/// (package `whisper_cpp`); a cloud implementation is optional.
abstract class Asr {
  String get name;
  Future<AsrResult> transcribe(Float32List samples, int sampleRate);
  Future<void> close();
}
