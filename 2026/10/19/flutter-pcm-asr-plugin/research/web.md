# Web: Web Speech API from a synthesized track (checked 2026-10-19)

Sources: the Web Speech API editor's draft, Chrome Platform Status, MDN
browser-compat-data, Microsoft Edge docs, Bugzilla, WebKit standards
positions, and an empirical run in branded Google Chrome 155 on macOS done
during this research (headless, fresh profile, page on `127.0.0.1`,
Japanese TTS clip converted to 16 kHz mono PCM16).

## Headline

In branded Chrome on desktop, `SpeechRecognition.start(track)` fed from PCM
through `AudioContext → AudioBufferSourceNode → MediaStreamAudioDestinationNode`
transcribes Japanese correctly **in cloud mode**. The recognizer does **not**
finalize when the track ends or is stopped; the page must call
`recognition.stop()`, after which the final result arrives in about 70 ms.
On-device ja-JP exists in Chrome but is a 60 MB download per browser profile.
Safari and Firefox take no track input at all.

## `start(MediaStreamTrack)`

- Spec: overload `start(MediaStreamTrack audioTrack)`; throws
  `InvalidStateError` unless the track is a live audio track; the
  microphone-permission flag is cleared. Nothing is said about the track
  ending. https://webaudio.github.io/web-speech-api/
- Chrome: shipped in desktop Chrome 135; Android "none"
  (https://chromestatus.com/feature/5178378197139456). MDN compat data:
  Chrome 135, Chrome Android false, Safari false, Firefox false; Edge follows
  Chrome. Microsoft's Edge docs show the same synthesized-track pattern and
  advise calling `recognition.stop()` on the media element's `ended`
  (https://learn.microsoft.com/en-us/microsoft-edge/web-platform/speech-recognition-api).
- Empirical, Chrome 155, `lang='ja-JP'`, 4.2 s clip:

  | Variant | Result |
  | --- | --- |
  | `continuous=false, interimResults=true`, track left live after the clip | interim results stream correctly; no `isFinal`, no `end` for 11 s |
  | same, `track.stop()` at the end of the clip | still no final within 7.7 s |
  | same, `recognition.stop()` at the end of the clip | `speechend`/`audioend` at once, **one `isFinal` result 67 ms later** ("今日は良い天気ですね 明日は東京へ行きます", confidence 0.918), then `end` |
  | `continuous=true, interimResults=false`, `track.stop()` | zero `result` events in 12 s |
  | `processLocally=true` with ja-JP not installed | immediate `error` `language-not-supported` (no cloud fallback) |

  A `MediaStreamAudioDestinationNode` plays in real time, so a 4 s chunk takes
  4 s; latency is chunk length plus about 0.1 s.
- Unbranded Chromium (the Claude desktop browser pane, Chromium 152) accepts
  `start(track)` but fails with `error network` and reports local ja-JP
  `unavailable`: no Google speech keys and no SODA component. The same is
  reported for Brave, Chrome for Testing and Playwright Chromium
  (https://github.com/amngy/glossa/issues/47).

## On-device recognition

- `processLocally`, `available()`, `install()`: desktop Chrome 139, Android
  none (https://chromestatus.com/feature/6090916291674112); `quality` option
  Chrome 150. About 60 MB per language pack, same download UI as the
  Translator API. 17 locales including ja-JP
  (https://github.com/WebAudio/web-speech-api/blob/main/explainers/on-device-speech-recognition.md).
  `available({langs:['ja-JP'], processLocally:true})` returned `downloadable`
  in Chrome 155; `install()` was not run (it downloads into the user's Chrome).
- With `processLocally: false` the audio goes to Google's speech servers
  (MDN; Chrome's own feature text contrasts the on-device mode with sending
  audio to a third-party service). Edge's cloud path uses Azure Cognitive
  Services.
- Edge on-device: Canary/Dev 150+ behind a flag, no Japanese (doc of 2026-06-01).
- Permissions-Policy `on-device-speech-recognition` (default `self`).

## Result semantics

- `continuous=false` → at most one final result; `interimResults` governs
  non-final ones; `isFinal` marks the last update of an index.
- `phrases` (contextual biasing) shipped in Chrome 142; `unspokenPunctuation`
  in 151; result timestamps in dev trial around 153.
- Errors: `no-speech`, `aborted`, `audio-capture`, `network`, `not-allowed`,
  `service-not-allowed`, `language-not-supported`, `phrases-not-supported`.

## Safari and Firefox

- Safari: prefixed `webkitSpeechRecognition` only (macOS 14.1 / iOS 14.5+),
  microphone only, built on `SFSpeechRecognizer`, not `SpeechAnalyzer`. Third
  parties report a prompt about sending data to Apple and failures offline;
  routing is not documented. WebKit's position on the on-device proposal is
  open with privacy concerns (https://github.com/WebKit/standards-positions/issues/443).
- Firefox: no `SpeechRecognition` in today's stable. On-device recognition
  (vendored parakeet.cpp, models via ModelHub) landed for Firefox 160 with "40
  languages" (https://bugzilla.mozilla.org/show_bug.cgi?id=2080908); Japanese
  is likely (the Nemotron model card lists ja-JP) but inferred. No track
  input, Android not enabled.

## Non-OS alternative

- whisper.cpp WASM is already working for Flutter Web in this project's
  earlier lab (`2026/10/18/flutter-realtime-audio-analysis/packages/whisper_cpp/WEB.md`):
  v1.9.5, SIMD128, CPU only; multi-thread needs cross-origin isolation. Model
  sizes: tiny 75 MiB, base 142 MiB, small 466 MiB. Licences MIT.
- transformers.js v3 + onnxruntime-web with WebGPU is the other route;
  WebGPU availability is uneven.

## Flutter Web mechanics

- `package:web` binds `SpeechRecognition.start([MediaStreamTrack])`,
  `AudioContext`, `AudioBuffer.copyToChannel`, `MediaStreamAudioDestinationNode`.
  Not bound: `processLocally`, `phrases`, `available()`, `install()`; declare
  them with `dart:js_interop`.
- A `MediaStreamTrack` cannot be constructed directly; the plugin owns a small
  `AudioContext` (sample rate 16000 honoured by Chrome) and a destination node.
  An `AudioContext` needs a user gesture to run in normal Chrome.
- CanvasKit has no constraint; skwasm needs cross-origin isolation from the
  host, which does not affect the Web Speech API but does affect whisper model
  hosting.

## Reading for the package

- The OS path on the Web is cloud recognition in branded Chrome/Edge on
  desktop, with `stop()` after real-time playback. It cannot be labelled
  on-device unless the user installed Chrome's language pack, and it does not
  exist on Chrome Android, Safari or Firefox.
- `RecognitionSupport` must say `onDevice: false` and name the browser's
  service; the app decides whether sending audio to Google is acceptable.
