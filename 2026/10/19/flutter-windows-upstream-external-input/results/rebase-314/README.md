# Core PR #314 rebased onto m150_release after #336

The core repository moved from webrtc-sdk/webrtc to livekit/libwebrtc, and
[#336](https://github.com/livekit/libwebrtc/pull/336) (aggregate audio mute state
across PeerConnections) rewrote `WebRtcVoiceSendChannel::MuteStream`, which made
[#314](https://github.com/livekit/libwebrtc/pull/314) conflict.

Rebased commit: `3dec523477e60f9ff6452d6d4a47dee520a1f1fa` on base
`7c1a802ab4e0d74f28ee997678346b3e753ef42a` (DEPS unchanged from the previous base).

- The mute/unmute guard moved into `WebRtcVoiceEngine::OnChannelMuteStateChange`:
  the APM mute still follows the aggregate; the ADM part (microphone mute and
  stop-on-mute start/stop) is skipped while `AudioState::recording_enabled()` is false.
- The voice tests were rewritten for the #336 fixture (`MicrophoneMuteAudioDevice`):
  disabled eager send, disabled mute/unmute in microphone-mute and stop-on-mute
  modes, and ordinary stop-on-mute unmute.

Windows x64, same GN args as the lab README, targets `audio_engine_tests` and
`media:rtc_media_unittests`:

| Build | AudioState | WebRtcVoiceEngine |
| --- | --- | --- |
| fix (`fix-*.json`) | 60/60 | 366 pass, 3 skipped, 4 adaptive-ptime fail (of 373) |
| guards removed, getter and tests kept (`control-*.json`) | 56/60 | 360 pass, 3 skipped, 10 fail: same 4 + 6 new cases |

The 4 adaptive-ptime failures (`SetRtpParametersAdaptivePtime`,
`AdaptivePtimeFieldTrial`) occur in both builds and are unrelated. The broad
178 common failures of the pre-rebase run are gone with the #336 fixture fixes.
Full presubmit, other-platform builds and the downstream ETW/runtime trials were
not re-run on the rebased commit.
