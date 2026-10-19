# Windows SDK requirements and alternatives

A custom WebRTC SDK is a dependency of the measured native lab implementation,
not a fundamental Windows requirement. A stock-SDK replacement preserving all
of this lab's guarantees has **not** been demonstrated.

## Public API and the actual gap

The wrapper already exposes `RTCAudioSource::kCustom` and `CaptureFrame` for
external PCM. That part can use the ordinary SDK. The lab changes the native
SDK because its automatic recording-initialization paths must be blocked and
because the owned speaker must be the sole clock pulling decoded audio.
`SetAudioRecording(false)` alone did not guard every initialization path in the
pinned native source; the lab patches AudioState and voice-send initialization.
`LabPullPlayout` and the recording-audit exports are lab additions.

The inspected pinned and main wrapper factory interfaces do not offer injection
of a custom audio-device module. Their public peer-connection interface does not
expose the native recording/playout toggles used by the patch. Disabling a track
or muting microphone samples is not evidence that no capture device was opened.

Primary sources inspected2026-10-19:

- [pinned external audio source API](https://github.com/webrtc-sdk/libwebrtc/blob/070aa6d763c16027ba53c0965107658c837a4dae/include/rtc_audio_source.h)
- [pinned peer-connection API](https://github.com/webrtc-sdk/libwebrtc/blob/070aa6d763c16027ba53c0965107658c837a4dae/include/rtc_peerconnection.h)
- [current wrapper factory API](https://github.com/webrtc-sdk/libwebrtc/blob/main/include/rtc_peerconnection_factory.h)
- [current factory creation API](https://github.com/webrtc-sdk/libwebrtc/blob/main/include/libwebrtc.h)

## Routes without maintaining a custom DLL

1. **Upstream support and official prebuilt SDK.** Add supported external-capture/
   playout controls or custom-ADM injection upstream, then consume an official
   release. This can preserve native flutter_webrtc integration, but depends on
   upstream implementation/release and is not an available tested workaround.
2. **A Windows browser backend, for example WebView2.** Feed native camera/record
   data into browser media tracks and use browser RTCPeerConnection. Microsoft
   confirms WebRTC support in WebView2; Web Audio can produce an audio MediaStream
   track without opening a physical microphone. This is a candidate architecture,
   not a validated replacement. It changes the Windows backend and requires
   Dart/native-to-JS transfer, clock/queue control and speaker/AEC integration.
   It does not directly reuse a native flutter_webrtc PeerConnection/track object.

Sources: [Microsoft WebView2 WebRTC support](https://github.com/MicrosoftEdge/WebView2Feedback/issues/226),
[Web Audio generated media track](https://developer.mozilla.org/en-US/docs/Web/API/MediaStreamAudioDestinationNode).

Merely distributing our prebuilt patched DLL removes **consumer-side builds**,
but still leaves a custom SDK and its maintenance. It is not a stock-SDK solution.
No alternate backend, public-API-only native path or all-platform replacement was
implemented or benchmarked as part of this API investigation.

The subsequent [stock native SDK experiment](../../flutter-windows-stock-sdk-external-capture/README.md)
tested official .03/.05 DLLs with external ETW observation. Active candidates
opened an additional SDK-owned capture client; the tested public processing/mute
settings did not establish recording isolation. See its results and separate
audio-decoder limitation rather than interpreting missing audit exports as zero.
