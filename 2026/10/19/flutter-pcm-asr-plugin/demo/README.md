# pcm_asr demo

Microphone → Silero VAD → streaming pyannote speaker-change detection → ECAPA
speaker ID → `pcm_asr` (the OS speech engine), on iOS, Android, Web and macOS.
Everything but the Web's recognition runs on the device; nothing is recorded
or saved.

Copied from the Mac-only lab app `2026/10/19/apple-speech-scd-asr/app`
(record, VAD, streaming SCD, speaker tracker, UI) with the native `apple_asr`
channel replaced by the `pcm_asr` plugin, `dart:io` removed from the UI, and
the ONNX models loaded per platform (`model_loader_io.dart` /
`model_loader_web.dart`). `lib/local/` is the analysis code of
`2026/10/18/flutter-realtime-audio-analysis/packages/audio_analysis` (ONNX
abstraction with the onnxruntime-web path, VAD, SCD, ECAPA).

Run it with the `demo-*` tasks of the lab (`mise run demo-ios`, `demo-android`,
`demo-web`, `demo-macos`); `mise run demo-prepare` fetches the pinned models.

- "実マイクを開始": listens until "停止して確定". Speak naturally; pause briefly
  when the speaker changes.
- "共有音声で試す": plays the shared two-speaker conversation at real time
  through the same pipeline.
- Each card: speaker candidate (ECAPA, not a person identity), time range,
  text, request→final ASR time, and time from the end of the speech to the
  text appearing.

Platform notes: iOS 16+ and macOS 14+ (flutter_onnxruntime), Android release
builds keep `ai.onnxruntime.**` from R8 (`proguard-rules.pro`; without it the
JNI aborts), the Web needs branded Google Chrome on `localhost` or https for
the microphone and sends audio to Google's speech service.
