# Stock SDK public API audit

## Scope and pins

This is source inspection, not proof of a physical microphone acquisition.
The runtime trials must determine whether the stock binary opens an additional
capture client while external PCM actually reaches the remote audio track.
The required architecture remains native Flutter WebRTC with continuous camera
and record capture. Browser backends, SDK rebuilds, binary patching, private ABI
casts, global device changes and deliberately failing microphone initialization
are outside the successful solution.

The original wrapper is [libwebrtc.m150.7871.03](https://github.com/webrtc-sdk/libwebrtc/releases/tag/libwebrtc.m150.7871.03),
commit `070aa6d763c16027ba53c0965107658c837a4dae`.
The latest release returned by the official release endpoint during inspection
was [libwebrtc.m150.7871.05](https://github.com/webrtc-sdk/libwebrtc/releases/tag/libwebrtc.m150.7871.05),
commit `f7e9e5904ca743066bbd8cc0e5676b7a08c48436`.
The observed native `m150_release` head was
`51c367e209f8f12b39bd8dd0ca70bf588f42cb48`, identical to the preceding lab's
native pin. No publication-time claim relative to the local clock is made.
Machine-readable pins are in [source-pins.json](../results/source-pins.json).

Both wrapper versions expose four `RTCAudioOptions` booleans: echo cancellation,
automatic gain control, noise suppression and high-pass filtering. Neither
exposes `init_recording_on_send`. Their public factory interface offers no custom
ADM injection; the public peer interface does not expose `SetAudioRecording`.
The .05 API was inspected as an alternative and then measured in a separate
header/importlib build. It is never relabeled as the .03 binary.

- [.03 audio options](https://github.com/webrtc-sdk/libwebrtc/blob/070aa6d763c16027ba53c0965107658c837a4dae/include/rtc_types.h#L115)
- [.05 audio options](https://github.com/webrtc-sdk/libwebrtc/blob/f7e9e5904ca743066bbd8cc0e5676b7a08c48436/include/rtc_types.h#L115)
- [.05 factory interface](https://github.com/webrtc-sdk/libwebrtc/blob/f7e9e5904ca743066bbd8cc0e5676b7a08c48436/include/rtc_peerconnection_factory.h)
- [.05 peer interface](https://github.com/webrtc-sdk/libwebrtc/blob/f7e9e5904ca743066bbd8cc0e5676b7a08c48436/include/rtc_peerconnection.h)

## Why a custom source can still activate the ADM

`kCustom` disconnects that local audio source from the default capture transport;
`CaptureFrame` supplies its data. It does not select a dummy ADM. The factory
still creates a platform-default ADM, and the send machinery operates it.
See [.03 factory implementation](https://github.com/webrtc-sdk/libwebrtc/blob/070aa6d763c16027ba53c0965107658c837a4dae/src/rtc_peerconnection_factory_impl.cc#L198)
and [.05 factory implementation](https://github.com/webrtc-sdk/libwebrtc/blob/f7e9e5904ca743066bbd8cc0e5676b7a08c48436/src/rtc_peerconnection_factory_impl.cc).

Three independent source paths matter at native commit `51c367e`:

1. [`WebRtcVoiceSendChannel::SetSend(true)`](https://github.com/webrtc-sdk/webrtc/blob/51c367e209f8f12b39bd8dd0ca70bf588f42cb48/media/engine/webrtc_voice_engine.cc#L1481)
   calls `InitRecording` when `options_.init_recording_on_send.value_or(true)`
   is true and the ADM is not already initialized or recording. Wrapper source
   creation copies the four public booleans but does not set this option.
2. [`AudioSendStream::Start`](https://github.com/webrtc-sdk/webrtc/blob/51c367e209f8f12b39bd8dd0ca70bf588f42cb48/audio/audio_send_stream.cc#L361)
   calls [`AudioState::AddSendingStream`](https://github.com/webrtc-sdk/webrtc/blob/51c367e209f8f12b39bd8dd0ca70bf588f42cb48/audio/audio_state.cc#L136).
   The latter initializes recording whenever `!adm->Recording()`. It checks
   `recording_enabled_` only after initialization, before starting. Thus even a
   hypothetical public `SetAudioRecording(false)` would not alone guarantee zero
   device initialization in this version.
3. [`WebRtcVoiceSendChannel::MuteStream`](https://github.com/webrtc-sdk/webrtc/blob/51c367e209f8f12b39bd8dd0ca70bf588f42cb48/media/engine/webrtc_voice_engine.cc#L1700)
   initializes and starts recording when a source becomes unmuted and the ADM's
   stop-on-mute mode is enabled. The native
   [`AudioDeviceModule::IsStopOnMuteModeEnabled`](https://github.com/webrtc-sdk/webrtc/blob/51c367e209f8f12b39bd8dd0ca70bf588f42cb48/api/audio/audio_device.h#L261)
   defaults to true; the inspected Windows ADM implementation has no override.

`WebRtcAudioSendStream::UpdateSendState` starts its stream only when `send_` and
encoding `active` are true. Setting `active=false` can stop this start path, but
not the channel-level eager initialization in path 1. Track disabling changes
mute state and cannot establish that no capture client was opened earlier.

## Field trials and constraints

The three recording branches above do not consult field trials. Field-trial
lookups in the inspected voice engine and send stream concern audio bandwidth,
packetization, RTP and related behavior; they do not gate these ADM calls.
The wrapper's `RTCMediaConstraints` conversion does not expose the missing
recording option either. Arbitrary constraint or field-trial strings are not
assumed effective merely because their syntax is accepted.

This is a bounded source conclusion: no supported bypass was found in these
pins. It is not a claim that every future SDK or alternative native implementation
must require a custom build.

## Runtime matrix and decision rule

| Trial condition | Question |
|---|---|
| Factory, custom source and track only | Is capture activated before sending? |
| Inactive or receive-only transceiver | Negative control with no outgoing media |
| Send-only custom track, enabled | Does real external PCM transmission acquire another capture client? |
| Disabled track during negotiation, then enabled | Does muting merely delay acquisition? |
| Encoding inactive, then active | Are RTP and device activation separate? |
| Replace track with null, then restore custom track | Does on-demand resume reacquire capture? |

Use the same long-lived record capture and identical injected PCM where possible.
Observe the SDK's capture clients independently of its audio samples or RTP
statistics. A useful successful trial must show actual received PCM/packets,
continuous record capture and no additional microphone acquisition together.

An extra stock-SDK capture client in an active transmission trial disproves that
candidate. Zero acquisition in a non-sending control is insufficient. An invalid
device index, denied access, endpoint exclusivity or global mute is not a
successful zero-acquisition architecture. A stock DLL cannot supply the earlier
custom recording-audit exports; missing exports must never be treated as zero
counters. Source analysis predicts failure of the active candidates, but the
runtime result is deliberately left to the lab's measured artifacts.

Runtime evidence is now retained in [summary.json](../results/summary.json):
tested active candidates initialized/started one extra SDK capture client.
Audio PCM decoding remained a separate unresolved failure; the capture observation
does not depend on claiming functional decoder success.
