import 'dart:typed_data';

import '../asr/asr.dart';
import '../dsp/pcm.dart';
import '../embedding/clap.dart';
import '../embedding/ecapa.dart';
import '../scd/speaker_change_detector.dart';
import '../tagging/yamnet.dart';
import '../vad/voice_detector.dart';
import 'audio_window_buffer.dart';
import 'events.dart';

/// Port of kiarina's `STTAudioConsumer` with diarization enabled. Split in
/// two stages so the cheap VAD keeps up with the mic while the expensive
/// part (change detection, ASR, embedding) runs behind a queue.
class SttConsumer {
  SttConsumer({
    required this.voiceDetector,
    required this.changeDetector,
    required this.asr,
    this.embedder,
    this.speakerSimilarityThreshold = 0.45,
    this.asrSpeakersOnly = false,
    this.asrMinSeconds = 0,
    this.newSpeakerMinSeconds = 0,
  });

  final VoiceDetector voiceDetector;
  final SpeakerChangeDetector changeDetector;
  final Asr asr;
  final EcapaSpeakerEmbedder? embedder;
  final double speakerSimilarityThreshold;

  /// Not in kiarina: skip ASR for speeches the change detector did not give
  /// a speaker (silence / overlap). On a real mic, Whisper turned such short
  /// stretches into "ご視聴ありがとうございました!".
  final bool asrSpeakersOnly;

  /// Not in kiarina: skip ASR (and speaker assignment) below this length.
  final double asrMinSeconds;

  /// Not in kiarina: a speech shorter than this never starts a new speaker;
  /// it joins the closest existing one (short ECAPA embeddings are noisy).
  final double newSpeakerMinSeconds;

  /// Embeddings seen per global speaker (kiarina keeps all; bounded here).
  final List<List<Float32List>> speakers = [];
  static const maxEmbeddingsPerSpeaker = 32;

  /// Stage 1: VAD. Returns a finished voice, if any.
  Future<VoiceDetectResult> detect(Float32List samples, int sampleRate, double timestamp) =>
      voiceDetector.detect(samples, sampleRate, timestamp);

  Voice? flush() => voiceDetector.flush();

  /// Stage 2: split a voice by speaker, transcribe and embed each speech.
  Future<List<SpeechEvent>> analyze(Voice voice) async {
    final speeches = await changeDetector.detect(voice.samples, voice.sampleRate, voice.startTimestamp);
    final events = <SpeechEvent>[];
    for (final speech in speeches) {
      final seconds = speech.samples.length / speech.sampleRate;
      String? skipped;
      if (asrSpeakersOnly && speech.kind != 'speaker') skipped = speech.kind;
      if (seconds < asrMinSeconds) skipped ??= 'short';
      var asrResult = AsrResult('');
      if (skipped == null) asrResult = await asr.transcribe(speech.samples, speech.sampleRate);
      Float32List? embedding;
      if (embedder != null && skipped == null) {
        embedding = await embedder!.embed(speech.samples, speech.sampleRate);
      }
      int? speaker;
      double? score;
      if (speech.kind == 'speaker' && skipped == null) {
        if (embedding != null) {
          final allowNew = seconds >= newSpeakerMinSeconds;
          // a short speech before anyone is known stays unassigned
          if (allowNew || speakers.isNotEmpty) {
            (speaker, score) = _resolveSpeaker(embedding, allowNew: allowNew);
          }
        } else {
          speaker = 0;
        }
      }
      events.add(SpeechEvent(
        start: speech.startTimestamp,
        end: speech.endTimestamp,
        speakerKind: speech.kind,
        speaker: speaker,
        speakerScore: score,
        text: asrResult.text,
        language: asrResult.language,
        asrMs: asrResult.elapsed.inMilliseconds,
        embedding: embedding,
        skipped: skipped,
      ));
    }
    return events;
  }

  /// Returns the global speaker and the best similarity to an existing one
  /// (null when there was none).
  (int, double?) _resolveSpeaker(Float32List embedding, {bool allowNew = true}) {
    var bestIndex = -1;
    var bestScore = -1.0;
    for (var i = 0; i < speakers.length; i++) {
      var score = -1.0;
      for (final v in speakers[i]) {
        final s = cosineSimilarity(embedding, v);
        if (s > score) score = s;
      }
      if (score > bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }
    final best = bestIndex >= 0 ? bestScore : null;
    if (bestIndex >= 0 && (bestScore >= speakerSimilarityThreshold || !allowNew)) {
      final list = speakers[bestIndex]..add(embedding);
      if (list.length > maxEmbeddingsPerSpeaker) list.removeAt(0);
      return (bestIndex, best);
    }
    speakers.add([embedding]);
    return (speakers.length - 1, best);
  }
}

/// Port of kiarina's `AmbientAudioConsumer` (10 s windows, YAMNet top-k and a
/// CLAP sound embedding per window).
class AmbientConsumer {
  AmbientConsumer({
    this.tagger,
    this.embedder,
    this.windowSeconds = 10,
    this.topK = 3,
    this.tagThreshold,
  }) : buffer = AudioWindowBuffer(windowSeconds: windowSeconds);

  final YamnetTagger? tagger;
  final ClapSoundEmbedder? embedder;
  final double windowSeconds;
  final int topK;
  final double? tagThreshold;
  final AudioWindowBuffer buffer;

  List<AudioWindow> accept(Float32List samples, int sampleRate, double timestamp) =>
      buffer.accept(samples, sampleRate, timestamp);

  List<AudioWindow> flush() => buffer.flush();

  Future<AmbientEvent> analyze(AudioWindow window) async {
    var tags = <TagPrediction>[];
    if (tagger != null) {
      tags = YamnetTagger.topK(await tagger!.predict(window.samples, window.sampleRate), topK, threshold: tagThreshold);
    }
    Float32List? embedding;
    if (embedder != null) {
      embedding = await embedder!.embed(window.samples, window.sampleRate);
    }
    return AmbientEvent(start: window.start, end: window.end, tags: tags, embedding: embedding);
  }
}
