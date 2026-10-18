# Windows external media input

## Current recording-isolated variant

The Windows external input plugin now requires the rebuilt, audited SDK from
[Windows recording isolation](WINDOWS_RECORDING_ISOLATION.md). Stock SDKs are
rejected at track creation. The tested protected lifecycle records zero ADM,
Windows backend, WASAPI and DMO recording initialization/start calls while one
real `record` capture keeps supplying PCM through two send phases. The same
DLL with the protection disabled exercises the recording initialization paths.
This is a pinned lab-specific variant, not a general-purpose SDK recording API.

The earlier stock-SDK results and failures below remain experimental evidence;
the current SDK build and use instructions are in the linked isolation document.

## Bridge

The independent `external_capture/windows` plugin links to the pinned
`flutter_webrtc` plugin and its libwebrtc wrapper. It creates and registers a
local stream with audio/video tracks in the same native factory used by
`flutter_webrtc`. The custom input sources do not themselves open a device;
however, the stock factory's default ADM attempts microphone initialization
when a custom audio track is sent. The audited variant suppresses these paths.

- Video: `CreateCustomVideoSource` → `RTCVideoSource::OnCapturedFrame`.
  Packed BGRA is converted to BT.601 limited-range I420 on the platform thread.
- Audio: `CreateAudioSource(..., kCustom)` → `RTCAudioSource::CaptureFrame`.
  PCM16 mono 48 kHz is accumulated into aligned 480-sample (10 ms) chunks.
- The native wrapper does not expose a video timestamp setter. The submitted
  `timestampUs` is currently ignored, and native injection time determines the
  frame timestamp. Precise capture-time synchronization remains unverified.
- Custom audio bypasses the default microphone audio transport; upstream
  WebRTC audio processing/AEC must not be assumed to apply to these samples.
- This is intentionally tied to `flutter_webrtc 1.6.2+hotfix.4` and its C++
  ABI. Access to the protected factory and local registries uses a derived
  pointer-to-member accessor; a production plugin should expose a supported
  registration API instead.

## Build details

Flutter 3.47.2 / Dart 3.13.2, Visual Studio 2022 C++ toolchain, Windows x64.
The app enables MSVC `/utf-8` because upstream sources otherwise fail C4819
under Japanese Windows with warnings treated as errors.

Plugin discovery orders `external_capture` before `flutter_webrtc` in CMake.
The link path uses `$<TARGET_PROPERTY:flutter_webrtc_plugin,SOURCE_DIR>` so
resolution occurs after all plugins have been defined.

Source references:

- [Pinned wrapper API](https://github.com/webrtc-sdk/libwebrtc/blob/libwebrtc.m150.7871.03/include/rtc_peerconnection_factory.h)
- [Audio input implementation](https://github.com/webrtc-sdk/libwebrtc/blob/libwebrtc.m150.7871.03/src/rtc_audio_source_impl.h)
- [Custom video factory](https://github.com/webrtc-sdk/libwebrtc/blob/libwebrtc.m150.7871.03/src/rtc_peerconnection_factory_impl.cc)
- [Video frame factory expects I420](https://github.com/webrtc-sdk/libwebrtc/blob/libwebrtc.m150.7871.03/src/rtc_video_frame_impl.cc)

## Verification

The Windows release app compiled successfully. The first synthetic run
created both kinds of external track and passed the initial idle phase
(75 source video frames and 286,080 source audio bytes, zero injected).

That run then exposed an upstream wrapper bug: `MediaStreamImpl::AddTrack`
rebuilds track lists synchronously in `OnChanged`, then appends the track
again. `mediaStreamGetTracks` therefore returned the last-added audio track
twice. Adding the duplicate track to a peer connection returned null.
The Dart bridge must construct exactly one track per returned ID instead of
using `getMediaTracks` on Windows. The failed result is preserved as
`results/windows-synthetic-initial-failure.json`.

The deduplication fix is applied in the Dart bridge. Subsequent native
loopback and independent receiver outcomes are recorded below.


The next run appeared to pass, but the original copied Windows tap ignored
`local: false` and called a lookup that prefers local tracks. In a same-process
loopback the remote ID matches the local ID, so this measured the sender.
`results/windows-synthetic-local-tap-invalid.json` is retained as an invalid
receiver measurement. RTP video decoding and audio packet reception occurred,
but the PCM/frame tap observations from that run do not establish remote
media delivery. The lab copy of the Windows tap now resolves remote tracks
through `RTCPeerConnection::receivers()` and never falls back to local tracks.

### Local receiver output failure

After resolving remote receiver tracks correctly, the Windows local loopback
reports a real failure: video decodes, but no remote PCM arrives. Native logs
show `IAudioClient::Initialize()` failing with HRESULT `0x88890008`
(`AUDCLNT_E_UNSUPPORTED_FORMAT`). The selected render endpoint only offers a
4-channel 48 kHz format, while this libwebrtc backend tests mono/stereo formats.
Audio RTP packets arrive, but NetEq has no successful render clock, leaving
`totalSamplesReceived` and `totalAudioEnergy` at zero. Selecting playout device
index 0 before creating the peer connection did not resolve this. This
unsuccessful endpoint override is not part of the final bridge.

### Live capture availability

The default Windows live capture run fails before collecting frames:
`CameraException(initialization_failed, Failed to enumerate camera media types)`.
Only two camera entries were present: Pixel Fold (Windows virtual camera),
and CyberLink Webcam Splitter 6.0. The capture helper supports
`EXTERNAL_CAMERA=<name substring>` to select an explicit camera and reports
its selected name. A physical camera capture has not been established.

### Independent receiver probe

`app/lib/windows_browser_probe.dart` runs a Windows native sender and an
independent headless Chrome receiver. It binds an HTTP signalling server to
loopback only and launches Chrome with a dedicated temporary profile. Browser
WebAudio pulls decoded remote audio through a muted gain node. The report
requires increasing browser `totalSamplesReceived` and `framesDecoded`, plus
nonzero WebAudio analyser RMS during each send interval. The temporary Chrome process is
terminated on completion.

Build with `flutter build windows --release -t lib/windows_browser_probe.dart`.
Set `EXTERNAL_SYNTHETIC=true` for controlled external BGRA / 440 Hz PCM inputs;
otherwise the probe uses camera + record. The report is written to
`%TEMP%/external_browser_result.json`.


### Stock SDK recording behavior

Native logs show `AudioDeviceModuleImpl::InitRecording` and `StartRecording`
even for `RTCAudioSource::kCustom`. In this environment StartRecording then
fails because the built-in AEC requires playout to have started first.
These stock-SDK runs prove external PCM injection but do not establish
exclusive microphone ownership by `record`. A working render endpoint could
cause the default ADM to acquire an additional capture handle. The prebuilt wrapper's public `RTCPeerConnection` and `RTCAudioDevice`
APIs expose no `SetAudioRecording(false)` or custom ADM installation hook.
The current lab-specific SDK adds native recording/initialization guards and
runtime counters without changing the public wrapper C++ ABI. Its measured
scope and remaining production/API limitations are documented in the isolation
experiment linked above.

The independent synthetic receiver test passes. The two send intervals decode
296,640 / 297,600 audio samples and 150 / 150 video frames, with measured
WebAudio RMS maxima 0.1727 / 0.1733 for the injected 440 Hz PCM. Idle intervals
keep producing source data while injecting zero bytes/frames. Chrome's muted
WebAudio path reports `totalAudioEnergy=0`, so the probe checks actual analyser
RMS together with increasing decoded samples instead of treating that stats
field as proof of silence. See `results/windows-browser-synthetic.json`.

The controlled real-microphone variant also passes: one `record` capture
remains open across both idle/send cycles while synthetic BGRA supplies video.
The receiver decodes 296,160 / 298,080 audio samples with RMS maxima
0.02194 / 0.03949, and 151 / 141 video frames. Maximum source callback gaps are
51 ms for audio and 44 ms for video. The actual camera is not used in this
variant. See `results/windows-browser-record.json`.

For this variant set `EXTERNAL_SYNTHETIC=false` and `EXTERNAL_REAL_AUDIO=true`.
The environment was Windows 11 Home Insider Preview 10.0.26220 x64, Chrome
155.0.8059.84, Core i9-12900K / GeForce RTX 3080 Ti / 64 GB. Device/ADM diagnostic
facts are summarized in `results/windows-environment-diagnostics.json`.

A final rebuild/run with a fresh temporary Chrome profile also passes and
removes the profile successfully. It decodes 295,680 / 297,600 audio samples
and 150 / 148 video frames (maximum source gaps: audio 49 ms, video 42 ms).
See `results/windows-browser-record-profile-cleanup.json`.
