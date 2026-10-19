# pcm_asr (working name, not published)

Final transcription of **finalized PCM segments** with the OS speech engine.
The caller owns the microphone, the voice activity detection and the speaker
handling; this plugin turns one finished segment into final text and hands the
caller's request ID back with it. It never records.

```dart
final asr = const PcmAsr();
final support = await asr.support(locale: 'ja-JP');   // read every field, not just `supported`
await asr.prepare(locale: 'ja-JP');                   // may download the OS model
final result = await asr.transcribe(TranscribeRequest(
  id: 'segment-12',
  locale: 'ja-JP',
  audio: PcmSegment(pcm16le: bytes, sampleRate: 16000, channels: 1),
));
print('${result.id}: ${result.text} (${result.elapsed.inMilliseconds} ms, ${result.engine})');
```

## Contract

- Input: interleaved signed 16-bit little-endian PCM, any sample rate the
  engine accepts (16 kHz mono is the reference input; Apple converts other
  rates, Android and Web require 16 kHz mono).
- One request, one final result. No partial results, no microphone.
- `RecognitionSupport` reports separately whether the engine exists, takes
  external PCM, runs on the device, and whether its model is installed,
  downloadable or unavailable. `supported == true` only means a request for
  that locale can succeed once `prepare` has completed.
- Errors are `PcmAsrException` with a stable `PcmAsrErrorCode`:
  `unsupportedPlatform`, `unsupportedLocale`, `modelUnavailable`,
  `invalidPcm`, `timeout`, `cancelled`, `engineFailure`.
- `cancel(id)` stops one request; `dispose()` stops all and releases the
  engine. `TranscribeRequest.timeout` cancels natively when it passes.

## Platforms (state of the lab, 2026-10-19)

| Platform | Engine | On device | Notes |
| --- | --- | --- | --- |
| macOS 26+ | `SpeechAnalyzer` + `SpeechTranscriber` | yes | one analyzer per request, `finalizeAndFinish`; model assets managed by the OS |
| iOS 26+ | same (shared `darwin/` source) | yes | needs hardware that reports `SpeechTranscriber.isAvailable`; no Simulator |
| Android 13+ (API 33) | `android.speech.SpeechRecognizer` fed by a pipe (`EXTRA_AUDIO_SOURCE`) | when the device has an on-device recognizer | verified on a Pixel 6; PCM is written as fast as the pipe accepts (a lab knob restores real-time pace); a 0.6 s silent tail is appended; `stopListening` is never called |
| Web | `SpeechRecognition.start(MediaStreamTrack)` | no (cloud, unless the user installed Chrome's language pack) | desktop Chrome/Edge 135+ only; audio goes to the browser vendor's servers |
| Windows | none | – | no OS engine takes external PCM for Japanese; `support()` reports `unsupportedPlatform` |

Measured numbers and the evidence are in the lab README one level up.
