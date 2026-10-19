# Android: SpeechRecognizer fed from a pipe (checked 2026-10-19)

Sources: AOSP `RecognizerIntent.java`, `SpeechRecognizer.java`,
`RecognitionService.java`, Android reference pages, and field reports on
GitHub. Field reports name the device when the author did.

## Headline

`android.speech.SpeechRecognizer` with `RecognizerIntent.EXTRA_AUDIO_SOURCE`
(API 33) reads raw PCM from a `ParcelFileDescriptor` instead of the
microphone. One field report does exactly this lab's job: a Flutter (Pigeon)
plugin feeding 16 kHz mono PCM16 through a pipe to
`createOnDeviceSpeechRecognizer` on a **Pixel 6, ja-JP, without
`RECORD_AUDIO`**, receiving Japanese transcripts
(https://github.com/goofmint/offline_stt, results in `spikes/android/RESULTS.md`
and `docs/e2e/E2E_RESULTS_ANDROID.md`). The same report lists the pitfalls
below. Support is recognizer-dependent and the fallback is silent: a
recognizer that ignores the extra opens the microphone.

## EXTRA_AUDIO_SOURCE

- Documented defaults match this lab's format: 1 channel,
  `ENCODING_PCM_16BIT`, 16000 Hz. Set `EXTRA_AUDIO_SOURCE_CHANNEL_COUNT`,
  `EXTRA_AUDIO_SOURCE_ENCODING`, `EXTRA_AUDIO_SOURCE_SAMPLING_RATE` anyway.
  The fd carries headerless PCM.
- "The recognition session will end when and only when the audio is closed."
  Closing the write end is the end-of-utterance signal. Do not call
  `stopListening()`: Google's on-device recognizer answers `ERROR_CLIENT` and
  drops the utterance; calling it after the pipe closed also gives `ERROR_CLIENT`.
- Who honours it (field): Google's default recognizer
  (`com.google.android.tts`) and the on-device one (`com.google.android.as`,
  `AiAiSpeechRecognitionService`, logs "Create input stream from external
  audio PFD") on a Pixel 6 and on an API 36 Google-APIs emulator
  (https://github.com/jaypetez/ideaforge/blob/main/spikes/android-recognizer/FINDINGS-emulator.md);
  expo-speech-recognition reports a Galaxy S23 Ultra on Android 14. One
  unnamed-device report got no results (https://github.com/stefm78/Experimental/pull/94).
- **Audio must be fed at real-time pace.** Dumping the PCM at full speed
  produced `ERROR_NO_MATCH` within a second (vivo X300 report); the ML Kit
  GenAI docs state the same requirement. goofmint's `RealtimePump` writes
  3200-byte (100 ms) chunks with wall-clock correction. Consequence: the
  request takes about the clip's length plus ~0.2 s. Whether a modest
  speed-up is tolerated is unmeasured.
- A Linux pipe holds 64 KiB (about 2 s of audio); write from a dedicated
  thread. Keep the read end open until the session ends: `startListening`
  only posts to the main looper, so closing the read fd right away hands the
  service a dead descriptor.

## On-device recognition and ja-JP on Pixel 6 (field)

- `isOnDeviceRecognitionAvailable() == true`; `checkRecognitionSupport`
  listed 36 supported on-device languages including ja-JP, but only en-US was
  installed on a fresh device. `triggerModelDownload` for ja-JP worked, yet its
  `ModelDownloadListener` fired at most `onScheduled`; completion had to be
  detected by polling `checkRecognitionSupport` (spurious `unavailable` 17 to
  20 % of the time under rapid calls, 0 % at 1 s spacing).
- Confidence on on-device finals is reported as 0.0; do not use it.
- `onResults` sometimes carries `RESULTS_RECOGNITION == null` after EOF on
  Pixel 6 (2 of 2 runs in the spike, 0 of 3 in the later E2E). Keep the last
  partial as the fallback. On the emulator the final text arrived in
  `onPartialResults` with `final_result=true` right after `onEndOfSpeech`, and
  `onResults` came 3.5 to 4 s later, empty.
- Long audio: a 3-minute pipe was accepted but the engine reset its
  hypothesis twice (~350 characters per reset). Short segments are safe.
- Keep **one** `SpeechRecognizer` instance per client and serialize
  create → check → listen → destroy. Destroying a second instance killed a
  live session with `ERROR_SERVER_DISCONNECTED` in 17 of 20 runs.

## Permission and indicator

- `RecognitionService.dispatchStartListening` skips the `RECORD_AUDIO`
  preflight when `EXTRA_AUDIO_SOURCE` is present, and skips the data-delivery
  check when the service created an attribution context for the caller.
  Google's on-device service evidently does: an app without `RECORD_AUDIO` in
  its manifest got results on the Pixel 6. Whether the default (network)
  Google recognizer behaves the same when fed an fd is unverified. Treat
  `ERROR_INSUFFICIENT_PERMISSIONS` as "this recognizer ignored the fd".
- No source observed the microphone privacy indicator; with no `AudioRecord`
  and no `RECORD_AUDIO` op it is expected to stay off (inference).

## Alternatives

- ML Kit classic has no speech API. ML Kit GenAI Speech Recognition
  (`genai-speech-recognition:1.0.0-alpha1`) accepts a PFD of raw 16 kHz mono
  PCM16 and lists ja-JP, but needs the AICore app, which is a stub on the
  Pixel 6 (`checkStatus()` → `PERMISSION_DENIED`). Not usable there.
- Android 15 and 16 added no transcription API; API 35 only added two
  language-switch extras to `RecognizerIntent`.
- Bundled engines, licences: whisper.cpp MIT, sherpa-onnx Apache-2.0, Vosk
  Apache-2.0 (Japanese model available).

## Flutter mechanics

- `Uint8List` ↔ `ByteArray` under the standard codec; one copy per side.
- `createSpeechRecognizer`, `createOnDeviceSpeechRecognizer`,
  `setRecognitionListener`, `startListening`, `cancel`, `destroy` must run on
  the main looper (`checkIsCalledFromMainThread`); callbacks arrive on the
  main looper. Write the pipe from a background thread.
- Reference implementation of the pipe pattern:
  https://github.com/goofmint/offline_stt/blob/main/packages/offline_stt/android/src/main/kotlin/com/moongift/offline_stt/RecognitionSession.kt
  and `RealtimePump.kt` in the same tree (licence to be checked before any copy).

## What to confirm on this project's Pixel 6

1. `checkRecognitionSupport` lists ja-JP installed, or `triggerModelDownload` installs it.
2. A 3 s pipe at real-time pace yields a `final_result=true` partial or a non-null `onResults`.
3. No `RECORD_AUDIO` in the manifest and no microphone indicator.
4. One recognizer instance, no `stopListening`, session ends on pipe close.
5. Whether feeding faster than real time is tolerated (latency would otherwise equal clip length).
