
import 'package:audio_analysis/audio_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:whisper_cpp/whisper_cpp.dart';

/// ggml models from huggingface.co/ggerganov/whisper.cpp (sha256 = LFS oid).
class WhisperModels {
  static ModelFile _m(String name, String sha256, int bytes) => ModelFile(
        id: 'whisper',
        url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$name.bin',
        sha256: sha256,
        bytes: bytes,
        filename: 'ggml-$name.bin',
      );

  static final all = <String, ModelFile>{
    'tiny': _m('tiny', 'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21', 77691713),
    'base': _m('base', '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe', 147951465),
    'base-q5_1': _m('base-q5_1', '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898', 59707625),
    'small': _m('small', '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b', 487601967),
    'small-q5_1': _m('small-q5_1', 'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb', 190085487),
    'medium': _m('medium', '6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208', 1533763059),
    'medium-q5_0': _m('medium-q5_0', '19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f', 539212467),
    'large-v3-turbo-q5_0':
        _m('large-v3-turbo-q5_0', '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2', 574041195),
  };
}

class WhisperAsr implements Asr {
  WhisperAsr._(this._engine, this.modelName, this.language, this.threads, this.fitAudioCtx);

  final WhisperEngine _engine;
  final String modelName;
  final String language;
  final int threads;
  final bool fitAudioCtx;

  static Future<WhisperAsr> load(ModelStore store, String modelName, {String language = 'ja', int threads = 0, bool fitAudioCtx = false}) async {
    final file = WhisperModels.all[modelName]!;
    final location = await store.ensure(file);
    final engine = kIsWeb
        ? await WhisperEngine.load(bytes: await store.readBytes(file))
        : await WhisperEngine.load(path: location);
    return WhisperAsr._(engine, modelName, language, threads, fitAudioCtx);
  }

  @override
  String get name => 'whisper.cpp $modelName${fitAudioCtx ? ' fit-audio-ctx' : ''} (${WhisperEngine.backend})';

  @override
  Future<AsrResult> transcribe(Float32List samples, int sampleRate) async {
    final pcm = resampleLinear(samples, sampleRate, 16000);
    final r = await _engine.transcribe(pcm, options: WhisperOptions(language: language, threads: threads, fitAudioCtx: fitAudioCtx));
    return AsrResult(r.text.trim(), language: r.language, elapsed: r.elapsed);
  }

  @override
  Future<void> close() => _engine.dispose();
}
