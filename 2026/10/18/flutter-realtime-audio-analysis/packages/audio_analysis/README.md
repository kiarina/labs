# audio_analysis

A Dart port of kiarina-python's audio analysis (`kiarina-agi-audio` and
`kiarina-agi-data-builder`'s `file_info_builder_impl/audio`, commit `9d483457`)
for real-time use in Flutter. It takes 16 kHz mono PCM and produces what was
heard: speeches (with speaker and text) and ambient windows (with sound tags and
a sound embedding), kept in a bounded store.

The package does not depend on a specific app or ASR: speech-to-text is an
interface (`Asr`), implemented in this lab's app with `whisper_cpp`.

## Pipeline

```text
feed(pcm) ─┬─ 512-sample chunks → SileroVad → VoiceDetector ──► voices
           │                                     [bounded queue]
           │        voices → SpeakerChangeDetector (pyannote) → speeches
           │               → Asr + EcapaSpeakerEmbedder → speaker index → SpeechEvent
           └─ AudioWindowBuffer (10 s) [bounded queue]
                    → YamnetTagger (top 3) + ClapSoundEmbedder → AmbientEvent
                                         └──────► HearingStore (1 h / 5000 events)
```

| Python (kiarina-agi-audio) | Dart |
| --- | --- |
| `SileroVADProvider` | `SileroVad` |
| `VoiceDetector` | `VoiceDetector` |
| `PyannoteSCDProvider` | `PyannoteScd` |
| `SpeakerChangeDetector` | `SpeakerChangeDetector` |
| `EcapaTDNNOnnxAudioEmbeddingProvider` | `EcapaSpeakerEmbedder` |
| `ClapOnnxAudioEmbeddingProvider` (NumPy log-mel) | `ClapSoundEmbedder` (same front end in Dart) |
| `YamnetAudioTaggingProvider` (TFLite) | `YamnetTagger` (the same TFLite converted to ONNX) |
| `AudioWindowBuffer` | `AudioWindowBuffer` |
| `STTAudioConsumer` (diarization on) | `SttConsumer` |
| `AmbientAudioConsumer` | `AmbientConsumer` |
| — | `AudioAnalyzer` (queues, stats), `HearingStore`, `ModelStore` |

## Differences from Python (on purpose)

- **YAMNet tags the whole window.** The pinned TFLite reads only
  `waveform[0:15600]` (0.975 s) and fails on shorter input, so kiarina tags a
  10 s window by its first second. `YamnetTagger` runs 0.975 s crops with a
  0.48 s hop and averages them; `firstCropOnly: true` reproduces kiarina.
- **`VoiceDetectorSettings.maxVoiceMs`** (default null = kiarina) cuts a voice
  that has no pause, so results keep coming during continuous talk.
- **Speaker history is bounded** (32 embeddings per speaker).
- **Optional guards from the real-mic check** (all off by default = kiarina):
  `asrSpeakersOnly` skips ASR for silence/overlap speeches (Whisper made up
  "ご視聴ありがとうございました!" for them), `asrMinSeconds` skips very short
  ones, and `newSpeakerMinSeconds` keeps short speeches from starting a new
  speaker (short ECAPA embeddings of the same person scored ~0.2; ≥1.5 s
  ones 0.49–0.59, different people ≤0.37). The lab app turns them on
  (0.5 s / 1.5 s).
- **Queues are bounded**; when a stage falls behind, the oldest item is dropped
  and counted in the stats.

## Runtimes

- ONNX: `flutter_onnxruntime` 1.9.0 on macOS, Windows, Android and iOS;
  on the web, onnxruntime-web is called directly (`WebOnnxBackend`), because
  flutter_onnxruntime's web side builds int64 tensors from `Int64List`, which
  dart2js lacks (Silero's `sr` input).
- Input metadata is not read (unavailable on iOS, macOS and web); input ranks
  are fixed per model.

## Tests

`flutter test` replays the Python fixtures (`../../fixtures`) through the
logic without ONNX Runtime: PCM conversion and 48 kHz resampling are
bit-identical, voice segments (4 settings) and speaker-change splits are
identical, and the CLAP log-mel differs by at most 7.6e-6 dB. The models
themselves are compared in the app's parity mode on each platform.
