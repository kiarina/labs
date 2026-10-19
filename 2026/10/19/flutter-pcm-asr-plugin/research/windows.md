# Windows: speech recognition from a PCM buffer, ja-JP, offline (checked 2026-10-19)

Target: a Flutter Windows plugin (C++), unpackaged exe by default, Windows 11,
16 kHz mono PCM16 in, one final string out, Japanese, preferably on device.

**There is no Microsoft-shipped on-device path that is at the same time usable
from an unpackaged exe, takes a PCM buffer and does Japanese today.**

| Path | Min Windows | Package identity | Internet | External PCM | Final per request | ja-JP | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `Windows.Media.SpeechRecognition` | 10 | **Required** (packaged or external location; stated in the docs since 2026-07) | **Yes** for dictation (web service; the Online speech recognition privacy toggle gates it) | **No** (default mic only) | Yes | Likely, unverified | Only list and SRGS constraints run on device, and those are command grammars |
| `Microsoft.Windows.AI.Speech` (Windows App SDK) | 11 24H2 (26100) | **Required**: MSIX with `systemAIModels`; external-location identity possibly enough, untested | Model download only (NPU on Copilot+ PCs, CPU elsewhere) | **Yes**: `BatchRecognition.Recognize(uint16[])`, `SpeechAudioProvider.PushData` (16 kHz 16-bit mono) | Yes | **No** (English only in the preview) | Experimental only (2.2.2-experimental9 of 2026-06 through 2.5.4-experimental of 2026-09); not allowed in Store apps |
| SAPI 5 in-proc (`ISpRecognizer::SetInput` with `ISpStream` over `IStream`) | 10/11 | No | No | **Yes** | Yes | **Unverified** on 11 24H2; Windows Speech Recognition was deprecated 2023-12 and replaced by Voice access | Plain COM from CMake; Vista-era models, expect poor Japanese dictation |
| Azure Speech SDK, embedded models | 11 x64/ARM64 | No | No | Yes (push stream, 16 kHz mono) | Yes | Yes | **Limited Access**: only Microsoft-managed customers get models and a licence key |
| Azure Speech SDK, cloud | 11 x64/ARM64 | No | **Yes** | Yes (`AudioInputStream::CreatePushStream` → `RecognizeOnceAsync`) | Yes | Yes | Needs an Azure key; audio leaves the device |
| Live Captions / Voice access models | 22H2 | – | – | **No public API** | – | – | Live Translation API listed as planned |
| Foundry Local (Microsoft) with Whisper | 11 (assumed) | Not mentioned | First model download | Whisper: file input; live PCM API is English-only (`nemotron-speech-streaming-en-0.6b`) | Yes | Whisper itself yes; the SDK's `Language` setting and the C API's audio client are unverified | Embeddable runtime (~20 MB, ONNX Runtime), C ABI + header-only C++ wrapper, no Azure subscription |
| Windows ML + own Whisper ONNX | 11 24H2 | No | No | Yes (own code) | Yes | Yes | Equivalent to shipping whisper.cpp yourself |

Sources:

- https://learn.microsoft.com/en-us/windows/apps/develop/input/speech-recognition
- https://learn.microsoft.com/en-us/uwp/api/windows.media.speechrecognition.speechrecognizer
- https://support.microsoft.com/en-us/windows/privacy/speech-voice-activation-inking-typing-and-privacy
- https://learn.microsoft.com/en-us/windows/ai/apis/speech-recognition
- https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.ai.speech.batchrecognition.recognize
- https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.ai.speech.audioconfiguration
- https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-notes/windows-app-sdk-2-0?pivots=experimental
- https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps
- https://heise.de/-11318683 (English-only preview)
- https://learn.microsoft.com/en-us/previous-versions/office/developer/speech-technologies/jj131729(v=msdn.10) (SAPI `SetInput`)
- https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features
- https://learn.microsoft.com/en-us/azure/ai-services/speech-service/embedded-speech
- https://learn.microsoft.com/en-us/legal/cognitive-services/speech-service/embedded-speech/limited-access-embedded-speech
- https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-use-audio-input-streams
- https://github.com/microsoft/Foundry-Local
- https://learn.microsoft.com/en-us/azure/foundry-local/how-to/how-to-transcribe-audio
- https://devblogs.microsoft.com/foundry/foundry-local-v1-1/

## Reading

- The OS engine cannot be declared supported for Japanese on Windows. The
  package must report `unsupported_locale` / `unsupported_platform` honestly
  there, or carry a non-OS backend.
- The only on-device candidates for Japanese are Whisper-class models the
  package ships or fetches itself (Foundry Local, or whisper.cpp as Spirits
  Garden already does). Whether to make that a separate adapter package is the
  open question for the owner.
- Keep `Microsoft.Windows.AI.Speech` on a watch list: its buffer API is the
  right shape, but it needs a Japanese model, a stable channel and package
  identity.
- SAPI is only worth a test if `SPCAT_RECOGNIZERS` on the target PC still lists
  a `MS-1041-…` token; nothing documents that for 24H2.

## Probe on this project's Windows PC (2026-10-19)

Machine: Core i9-12900K desktop, Windows 11 25H2 (build 26220), Japanese
locale, `Language.Speech~~~ja-JP` installed. Probes and logs:
`tools/windows/` and `results/windows/`.

- Recognizer tokens present: classic `MS-1041-80-DESK` ("Microsoft Speech
  Recognizer 8.0 for Windows (Japanese - Japan)") under `SPCAT_RECOGNIZERS`,
  and OneCore `MS-1041-110-WINMO-DNN` ("Microsoft Speech Recognition Engine -
  ja-JP Embedded DNN v11.1") under `HKLM\SOFTWARE\Microsoft\Speech_OneCore\Recognizers`.
- **Classic SAPI desktop recognizer, dictation from the fixture WAVs** (both
  through `System.Speech` and through an in-process `ISpRecognizer` with an
  `ISpStream` over memory): returns one or two characters per segment
  ("今", "で", "こぎ"), normalized CER 97 %. Mechanically it works
  (stream input, final result per segment, 10 to 70 ms), but the engine is
  unusable for Japanese dictation.
- **OneCore DNN engine through SAPI in-process**: `SetRecognizer` and
  `CreateRecoContext` succeed, but `LoadDictation` fails with
  `SPERR_NOT_FOUND` (0x8004503a) for every topic name and load option, and a
  dynamic rule grammar commits with `SP_NO_RULES_TO_ACTIVATE` and recognizes
  nothing. The modern on-device Japanese model is not reachable through SAPI.

Conclusion for the package: **no OS speech engine on Windows takes external
PCM for Japanese today.** `support()` must report `unsupported` on Windows,
and Japanese on Windows needs a non-OS backend (whisper.cpp, which Spirits
Garden already ships, or Foundry Local's Whisper).
