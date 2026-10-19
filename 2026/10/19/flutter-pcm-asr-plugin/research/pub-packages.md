# Existing pub.dev packages and external PCM input (checked 2026-10-19)

Question: does any published Flutter package already take a caller-supplied,
finalized PCM segment and return the OS speech engine's final text on
macOS, iOS, Windows, Android and Web? Package pages read on pub.dev; API
facts read from each repository's default branch on the same day.

| Package | Version / license | Platforms | OS API | External PCM input |
| --- | --- | --- | --- | --- |
| [speech_to_text](https://pub.dev/packages/speech_to_text) | 7.5.0, BSD-3 | Android, iOS, macOS, Web, Windows (beta) | Apple `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` fed by an `AVAudioEngine` tap; Android `android.speech.SpeechRecognizer` (no `EXTRA_AUDIO_SOURCE`); Windows SAPI in-proc with `SpMMAudioIn` (mic); Web Speech API | No. `listen()` owns the mic |
| [flutter_native_speech_to_text](https://pub.dev/packages/flutter_native_speech_to_text) | 1.3.0, MIT | Android, iOS, macOS, Web; Windows, Linux untested | Android system dialog (`ACTION_RECOGNIZE_SPEECH` activity); Apple `SFSpeechRecognizer` + mic tap; Windows `Windows.Media.SpeechRecognition` (mic only); Linux Vosk | No. `getAudio` returns the recorded audio, it is not an input |
| [liquid_speech](https://pub.dev/packages/liquid_speech) | 0.1.1, MIT, stale since 2025-11 | iOS, macOS | `SpeechAnalyzer` + `SpeechTranscriber`, locale hard-coded `en_US`, mic tap | No |
| [speech_kit](https://pub.dev/packages/speech_kit) | 0.0.2, BSD-3 | macOS only | `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`, `AssetInventory` through Dart build hooks + FFI (`swiftc` at build time) | **Yes**: `analyzePcm(Uint8List, format:, modules:)` copies bytes into an `AVAudioPCMBuffer`, runs `analyzeSequence` then `finalizeAndFinish(through:)`. Not a Flutter plugin, no iOS |
| [apple_speech](https://pub.dev/packages/apple_speech) | 0.1.0, MIT | iOS, macOS | Pigeon plugin with shared Darwin source. `SpeechAnalyzer` family on OS 26+, legacy `SFSpeechRecognizer` (file and mic, `requiresOnDeviceRecognition` honoured) below. Author reports verification on macOS 27 and an iOS 27 iPhone | Not exposed (`AudioSource` is file, asset or microphone); the live path already yields `AnalyzerInput(buffer:)` so a pushed-PCM source would be a small addition |
| [cupertino_fundations_models](https://pub.dev/packages/cupertino_fundations_models) | 1.9.0, MIT | iOS, macOS | `transcribeAudio` from a file path; live mode owns the mic | File only |
| [fluidaudio_dart](https://pub.dev/packages/fluidaudio_dart) | 0.4.0, MIT | macOS 14+, iOS 17+ | Own CoreML Parakeet models, not the OS engine | `transcribe(Float32List)` |
| [google_mlkit_genai_speech_recognition](https://pub.dev/packages/google_mlkit_genai_speech_recognition) | 0.3.1 | Android with AICore | Mic stream | No |

Nothing on pub.dev feeds external audio into `android.speech.SpeechRecognizer`
(`RecognizerIntent.EXTRA_AUDIO_SOURCE`, API 33). The Web Speech API has no
buffer input, so no package can offer it on the Web.

## Reading

- A new package is needed. No existing one covers the PCM-in / final-text-out
  contract on more than one platform, and the one that does (speech_kit) is
  macOS-only and not a Flutter plugin.
- Apple: the Swift pattern is settled (`AnalyzerInput(buffer:)`, `analyzeSequence`,
  `finalizeAndFinish(through:)`); speech_kit and apple_speech are permissively
  licensed references, and apple_speech also shows the pre-26 fallback
  (`SFSpeechAudioBufferRecognitionRequest.append` → `endAudio()` → wait for `isFinal`).
- Android: must be written from scratch around `EXTRA_AUDIO_SOURCE`; whether
  Google's recognizer honours it on a Pixel is the open question
  ([android.md](android.md)).
- Windows: SAPI could read a memory stream (`ISpRecognizer::SetInput` with an
  `ISpStream`), but every package wires the mic, and the engine is deprecated
  ([windows.md](windows.md)).
