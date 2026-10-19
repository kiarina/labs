# Apple: SpeechAnalyzer from a PCM buffer on iOS and macOS (checked 2026-10-19)

Sources: Apple documentation JSON, the `Speech.swiftinterface` of the iOS 27.1
SDK in Xcode 27.1, Apple's WWDC25 sample, Apple developer forum threads with
Apple engineers' answers. Items marked *unverified* were not confirmed on a
device by the source.

## SpeechAnalyzer on iOS

- Same API as macOS: `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`,
  `AnalyzerInput` are all available from iOS 26 / iPadOS 26 / macOS 26 (not
  watchOS). The public declarations of the macOS and iOS 27.1 swiftinterfaces
  are identical.
- The gate is hardware, not Apple Intelligence: `SpeechTranscriber.isAvailable`
  and `supportedLocales` (empty when unavailable). Apple publishes no device
  list and tells developers to check at runtime
  (https://developer.apple.com/forums/thread/802863). An Apple engineer said
  A16 iPads qualify and older hardware should use `DictationTranscriber`
  (https://developer.apple.com/forums/thread/801197). Community reports:
  iPhone 12 and later work, iPhone 11 / SE 2nd gen (A13) report `false`
  (*unverified*, https://developer.apple.com/forums/thread/806765).
- The iOS Simulator does not support it (`isAvailable == false`); Apple's own
  sample says so. Test on a physical device.
- `DictationTranscriber` (iOS 26) is the same pipeline with the system
  dictation models for hardware that `SpeechTranscriber` rejects.

## Japanese and model assets

- Japanese was in the launch language list of WWDC25 session 277; a Japanese
  blog prints `ja-JP` in `supportedLocales` and `supportedLocale(equivalentTo: "ja-JP")`
  → `ja_JP`. Always pass the locale returned by `supportedLocale(equivalentTo:)`;
  building `Locale(identifier:)` yourself produced
  `SFSpeechErrorDomain Code=10 "Cannot use modules with unallocated locales"`
  (https://developer.apple.com/forums/thread/790108).
- Assets are downloaded from Apple, stored and updated by the system, shared
  between apps and kept across launches (https://developer.apple.com/documentation/speech/assetinventory).
  `assetInstallationRequest(supporting:)` returns nil when already installed;
  `downloadAndInstall()` needs network the first time. Apps cannot delete
  assets; they `release(reservedLocale:)` and the system removes them later.
  `maximumReservedLocales` depends on the device.

## Privacy and permissions

- Apple's permission page states that the authorization flow applies only to
  `SFSpeechRecognizer` and that "SpeechAnalyzer transcriber modules don't send
  audio data of the user's voice to Apple's servers"
  (https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition).
- `NSSpeechRecognitionUsageDescription` is required only for APIs that send
  audio to Apple's servers. Apple's WWDC25 sample ships only
  `NSMicrophoneUsageDescription` and never calls `requestAuthorization`. A
  buffer-only SpeechAnalyzer path therefore needs no speech authorization and
  no microphone key. Keep the usage description if an `SFSpeechRecognizer`
  fallback is shipped: `requestAuthorization` crashes without it.
- Speech is not a "required reason" API; the privacy manifest can stay empty.

## Fallback below OS 26: SFSpeechRecognizer

- `SFSpeechAudioBufferRecognitionRequest.append(AVAudioPCMBuffer)` then
  `endAudio()`; `shouldReportPartialResults = false`; wait for `isFinal`.
- `requiresOnDeviceRecognition = true` is honoured only when
  `supportsOnDeviceRecognition` is true; otherwise it needs network, is
  throttled per device and app, and stops tasks longer than one minute.
  On-device Japanese is listed on Apple's feature-availability page but
  `supportsOnDeviceRecognition` is reported as flaky until the dictation pack
  is installed (https://developer.apple.com/forums/thread/125969).
- Always requires `requestAuthorization` and the usage description.

## SpeechAnalyzer semantics worth knowing

- The analyzer does not resample or convert. `bestAvailableAudioFormat` returns
  nil while assets are not installed; `availableCompatibleAudioFormats` lists
  what a module accepts. A mismatched buffer fails silently (no results). The
  earlier lab and this lab saw 16 kHz mono int16 accepted directly on macOS;
  convert with `AVAudioConverter` otherwise (`primeMethod = .none` to keep
  timestamps aligned).
- iOS 27 / macOS 27 add `AnalyzerInputConverter`, `AnalyzerInput(buffer: CMReadySampleBuffer)`
  and `Options.ignoresResourceLimits`; none exist on 26.
- Concurrency: one input sequence per analyzer; the system limits simultaneous
  analyses and throws `insufficientResources`. Serialize requests.
- `modelRetention`: `.whileInUse`, `.lingering`, `.processLifetime`.
  `prepareToAnalyze(in:)` preheats. A finished analyzer cannot be reused.
- Finishing: `finalizeAndFinish(through:)` with the value returned by
  `analyzeSequence`; nil means `cancelAndFinishNow()`. Ending the stream alone
  does not finish.
- `isFinal` ⇔ `resultsFinalizationTime >= range.end`. With preset
  `.transcription` only final results are reported; join them after finish.
- Third-party latency reports: 0.3 to 0.5 s to the first volatile result on an
  iPhone 16e (iOS 26.5); median 125 to 132 ms after speech on an M5 Max.
- `SFSpeechError.Code` on 26: `audioDisordered`, `unexpectedAudioFormat`,
  `incompatibleAudioFormats`, `assetLocaleNotAllocated`,
  `tooManyAssetLocalesAllocated`, `cannotAllocateUnsupportedLocale`, `noModel`,
  `insufficientResources`.

## Flutter plugin mechanics (Flutter 3.47.2)

- The plugin template emits both a podspec and `Package.swift`
  (swift-tools 5.9, Swift 5 language mode). Keep both until Flutter drops
  CocoaPods. A shared `darwin/` directory with `sharedDarwinSource: true`
  serves iOS and macOS from one source tree.
- Swift 6 strict concurrency trips over the non-Sendable Flutter codec types;
  stay in Swift 5 mode and keep the engine in an actor.
- `Uint8List` crosses the channel as `FlutterStandardTypedData` with one copy
  per side; a few seconds of 16 kHz PCM16 (100 to 200 KB) is negligible.
- Method handlers run on the main thread; wrap the work in a `Task` and reply
  from it (reply callbacks are thread-safe).
