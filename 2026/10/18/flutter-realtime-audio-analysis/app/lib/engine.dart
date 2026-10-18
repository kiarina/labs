import 'package:audio_analysis/audio_analysis.dart';

import 'whisper_asr.dart';

/// Where YAMNet (converted to ONNX in this lab) comes from. It is not hosted
/// publicly, so by default it is shipped in the app (`mise run prepare`
/// copies it); `YAMNET_URL` can point at a server instead.
const yamnetUrl = String.fromEnvironment('YAMNET_URL', defaultValue: 'asset:assets/models/yamnet.onnx');
const yamnetSha256 = String.fromEnvironment('YAMNET_SHA256',
    defaultValue: '8b977c9434c28c29d769e4d9e90b8e9752cdf9aaf6465eaa90a8eb535e83c46c');
const yamnetBytes = int.fromEnvironment('YAMNET_BYTES', defaultValue: 4999860);

ModelFile get yamnetOnnx => ModelCatalog.yamnetOnnx(url: yamnetUrl, sha256: yamnetSha256, bytes: yamnetBytes);

class EngineConfig {
  const EngineConfig({
    this.whisperModel = 'base',
    this.language = 'ja',
    this.diarization = true,
    this.ambient = true,
    this.threads,
    this.whisperThreads = 0,
    this.fitAudioCtx = false,
    this.maxVoiceMs = 15000,
    this.minSilenceMs = 500,
    this.speakerThreshold = 0.45,
    this.asrSpeakersOnly = true,
    this.asrMinSeconds = 0.5,
    this.newSpeakerMinSeconds = 1.5,
  });

  final String whisperModel;
  final String language;
  final bool diarization;
  final bool ambient;
  /// ONNX Runtime intra-op threads (null = runtime default).
  final int? threads;

  /// whisper.cpp threads (0 = whisper's default, min(4, cores)).
  final int whisperThreads;

  /// Shrink whisper's 30 s encoder window to each utterance (audio_ctx).
  final bool fitAudioCtx;

  /// kiarina's VoiceDetector default is 500.
  final int minSilenceMs;

  /// kiarina's speaker_similarity_threshold is 0.45.
  final double speakerThreshold;

  /// Not in kiarina (see SttConsumer).
  final bool asrSpeakersOnly;
  final double asrMinSeconds;
  final double newSpeakerMinSeconds;

  /// Longest voice before it is cut without a pause (null = kiarina's unlimited).
  final int? maxVoiceMs;

  List<ModelFile> get files => [
        ModelCatalog.sileroVad,
        ModelCatalog.pyannoteSegmentation,
        if (diarization) ModelCatalog.ecapaTdnn,
        if (ambient) ...[ModelCatalog.clapAudio, ModelCatalog.yamnetClassMap, yamnetOnnx],
        WhisperModels.all[whisperModel]!,
      ];
}

class LoadTimes {
  final ms = <String, int>{};

  Map<String, Object?> toJson() => ms;
}

/// Everything loaded once and kept: the ONNX sessions and the whisper context.
class Engine {
  Engine._(this.config, this.analyzer, this.asr, this.models, this.loadTimes);

  final EngineConfig config;
  final AudioAnalyzer analyzer;
  final Asr asr;
  final List<OnnxModel> models;
  final LoadTimes loadTimes;

  static Future<void> download(ModelStore store, EngineConfig config, void Function(ModelProgress) onProgress) async {
    for (final f in config.files) {
      await store.ensure(f, onProgress: onProgress);
    }
  }

  static Future<Engine> load(ModelStore store, EngineConfig config, {HearingStore? hearing}) async {
    final backend = defaultOnnxBackend(threads: config.threads);
    final times = LoadTimes();
    final models = <OnnxModel>[];

    Future<T> timed<T>(String name, Future<T> Function() f) async {
      final sw = Stopwatch()..start();
      final r = await f();
      times.ms[name] = sw.elapsedMilliseconds;
      return r;
    }

    Future<OnnxModel> onnx(String name, ModelFile f) => timed(name, () async {
          final m = await backend.load(await store.ensure(f));
          models.add(m);
          return m;
        });

    final vad = SileroVad(await onnx('silero_vad', ModelCatalog.sileroVad));
    final scd = PyannoteScd(await onnx('pyannote', ModelCatalog.pyannoteSegmentation));
    final ecapa = config.diarization ? EcapaSpeakerEmbedder(await onnx('ecapa', ModelCatalog.ecapaTdnn)) : null;
    final asr = await timed('whisper_${config.whisperModel}',
        () => WhisperAsr.load(store, config.whisperModel, language: config.language, threads: config.whisperThreads, fitAudioCtx: config.fitAudioCtx));

    AmbientConsumer? ambient;
    if (config.ambient) {
      final labels = YamnetTagger.parseClassMap(await store.readText(ModelCatalog.yamnetClassMap));
      final yamnet = YamnetTagger(await onnx('yamnet', yamnetOnnx), labels);
      final clap = ClapSoundEmbedder(await onnx('clap', ModelCatalog.clapAudio));
      ambient = AmbientConsumer(tagger: yamnet, embedder: clap);
    }

    final analyzer = AudioAnalyzer(
      stt: SttConsumer(
        voiceDetector: VoiceDetector(vad, settings: VoiceDetectorSettings(maxVoiceMs: config.maxVoiceMs, minSilenceMs: config.minSilenceMs)),
        changeDetector: SpeakerChangeDetector(scd),
        asr: asr,
        embedder: ecapa,
        speakerSimilarityThreshold: config.speakerThreshold,
        asrSpeakersOnly: config.asrSpeakersOnly,
        asrMinSeconds: config.asrMinSeconds,
        newSpeakerMinSeconds: config.newSpeakerMinSeconds,
      ),
      ambient: ambient,
      store: hearing,
    );
    return Engine._(config, analyzer, asr, models, times);
  }

  Future<void> close() async {
    await analyzer.close();
    await asr.close();
    for (final m in models) {
      await m.close();
    }
  }
}
