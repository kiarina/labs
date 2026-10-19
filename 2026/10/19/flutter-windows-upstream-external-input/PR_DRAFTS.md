# Upstream draft pull requests

No PR has been submitted. The core change is ready for a bounded draft review;
this is not a claim of a clean broad regression run or complete product support.
Ask the owner before creating a public fork or submitting upstream.

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

Patch: [sdk/factory-policy.patch](sdk/factory-policy.patch), based on
`f7e9e5904ca743066bbd8cc0e5676b7a08c48436`. Requires the core policy fix above;
use the final upstream core PR/release reference before submission.

Keep the exported no-argument factory and add an options overload, defaulting to
ordinary recording. Copy the policy into the factory, apply disabled recording
before exposing each native connection, and reject microphone sources/tracks
created through an external-only factory. Specify external-mode source/track
ownership carefully: foreign track use is outside the supported contract, and a
separate ordinary factory may intentionally capture. This is not a process-wide
microphone block. The final public header wording/API shape remains reviewable.

Three AudioDevice tests pass: existing enumeration/no-argument use, custom input
with two external connections, and copied options/default-factory independence
including rejection of a foreign microphone source in CreateAudioTrack. The
older official05-header Flutter binaries run unchanged against the candidate
DLL with exit0/errors0 and the expected loaded hash. That tests the exercised
interfaces, not exhaustive ABI certification. Independent ETW/media results are
retained in the validation lab. Ordinary native output-format failure and the
missing public wrapper playout/clock control remain separate limitations.

Do not include the diagnostic protected-member access, lab environment controls,
media-tap plugin, AEC, mixer-pull APIs or observation tools in this PR. Flutter's
initialize integration is a later thin change after official SDK support exists.

Wrapper main was rechecked at `9f6a87af46a5810a452aa20306c705b7c5269fbe` after
its desktop-capture update. The eight candidate target files are byte-identical
to the tested f7e9 source and the factory patch applies. That main revision was
not built; keep the tested pin and rebuild before the dependent wrapper PR.
See [head audit](results/wrapper-head-audit.json).
