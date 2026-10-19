# Upstream draft pull requests

Core Draft PR: [webrtc-sdk/webrtc#314](https://github.com/webrtc-sdk/webrtc/pull/314),
submitted on 2026-10-19 from [kiarina/webrtc](https://github.com/kiarina/webrtc),
commit `543b9cb70ee7b07311d4f4ddefc014278d6066d4`. The wrapper PR remains unsubmitted.
This is not a claim of a clean broad regression run or complete product support.

## Core: webrtc-sdk/webrtc → m150_release

Title: **Honor disabled recording during sender initialization and unmute**

Patch: [sdk/core-policy.patch](sdk/core-policy.patch), six files, based on
`51c367e209f8f12b39bd8dd0ca70bf588f42cb48`.

### Proposed body

When device recording is disabled through AudioState::SetRecording(false),
sender setup can still initialize the recording device, and unmuting can restart
it. This matters for applications that supply externally captured PCM: creating
a custom media source does not itself prevent another microphone client.

Use the same recording-enabled policy in AudioState sending-stream registration,
voice-channel eager initialization and the mute/unmute device branch. Recording
remains enabled by default. The meaning of init_recording_on_send stays limited
to eager initialization; false does not ban eventual ordinary recording.

The AudioState getter follows the worker-sequence contract. Adding the abstract
getter requires custom AudioState implementations to provide it. The comment
clarifies device-capture ownership: independently fed custom sources are not a
global transmission gate. Please confirm that the stronger no-initialization
contract is appropriate for this API.

Validation on Windows x64:

- Native audio_engine_tests and rtc_media_unittests built successfully.
- AudioState:60/60 pass. Ten focused voice tests pass, including disabled eager
  send/unmute, ordinary unmute and the existing initialization-option cases.
- With the same harness/getter but all three production guards restored to the
  old behavior, eight corresponding cases fail. Restoring the fix passes them.
- The broader310-case voice run still has178 failing tests, also failing in the
  control (182 failures there). No newly failing test names. These are mainly
  strict-mock expectations around ordinary mute/unmute setup; this is not an
  all-green upstream test suite. Full presubmit/other-platform builds have not
  been run.
- A separate downstream wrapper candidate applies disabled recording before
  exposing any connection. Independent Windows Audio Client ETW, with positive
  capture controls and loss0, observes one continuous record/MF client and zero
  SDK capture attempts. The same DLL's ordinary factory opens one SDK capture
  client; its external-input default-factory control opens MF1+SDK1.
- Real record PCM reaches decoded media with repeated track disable/enable and
  replaceTrack(null)/restore while
  the external-only factory remains at SDK capture0. This uses standard native
  SetAudioPlayout(false)/NullAudioPoller to diagnose an existing output-format
  failure; accessing that API currently needs source-matched wrapper internals
  in the lab. No mixer-pull or recording-audit export is added to the SDK.

This diff contains no factory opt-in API, Flutter integration, AEC algorithm,
playout control or device-format workaround. Those are separate downstream work.
Physical Windows camera, speaker/AEC quality, other devices and other OS builds
are not established by this experiment.

Evidence and limitations:
[validation lab](https://github.com/kiarina/labs/tree/main/2026/10/19/flutter-windows-upstream-external-input),
[core differential tests](https://github.com/kiarina/labs/blob/main/2026/10/19/flutter-windows-stock-sdk-external-capture/results/core-policy-native.json).

## Wrapper: webrtc-sdk/libwebrtc → main (dependent; do not submit yet)

Title: **Add an immutable external-audio-only factory policy**

Submission candidate: [latest-main wrapper proposal](upstream/wrapper/README.md),
[patch](upstream/wrapper/factory-policy.patch) and
[ready body](upstream/wrapper/PR_BODY.md). Based on main
`9f6a87af46a5810a452aa20306c705b7c5269fbe`, with all 25 wrapper tests passing
on Windows x64 (including four AudioDevice tests). Requires
[core PR #314](https://github.com/webrtc-sdk/webrtc/pull/314).

The original `sdk/factory-policy.patch` and f7e9 source pin remain the measured
ETW/ABI candidate. They are not replaced by the latest-main proposal. Latest-main
build/test evidence is in `upstream/wrapper/validation.json`; ETW, old-binary
runtime, other OS builds and full presubmit were not repeated for the new DLL.
No wrapper fork or PR has been published. Publication requires owner approval.
