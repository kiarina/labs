# Upstream preparation: external audio without device capture

**Worth pursuing; proposal/draft stage, not yet submission-ready.** No upstream
PR has been opened. The included first patch has only passed pinned-source hash
and `git apply` checks. It has not been compiled or run through native tests, and
it does not implement the complete external-only policy.

## Why this is a useful upstream feature

The stock native experiment reproduced an extra successful SDK capture client
with official .03/.05 binaries while externally acquired record PCM remained
active. ETW had loss0 and caller stacks identified SDK/DMO versus MF capture.
Muted and processing-flags-false cases did not prevent capture. This gives a
small reproducible resource/privacy problem and objective acceptance criteria.
The rationale is independent of Flutter-specific capture libraries: applications
already supplying PCM should be able to select a no-device-capture factory.

The stock lab also failed to decode received PCM on its output device. That is a
separate unresolved failure and cannot be advertised as successful media transfer
in the upstream report. Audio RTP arrival/video decode are the narrower evidence.

## Proposed split

### 1. Native recording-disabled consistency

Target the SDK's native fork first, pinned at
`webrtc-sdk/webrtc@51c367e209f8f12b39bd8dd0ca70bf588f42cb48` for reproduction.
Keep ordinary recording enabled by default. Make the explicitly disabled policy
cover all three recording paths:

- AudioState sending-stream registration must not initialize/start recording.
- Voice send eager initialization must also respect the same policy.
- Mute/unmute must not restart the device while that policy is disabled.

A policy getter on AudioState (worker-thread access, updated mocks/tests) is one
clean way for voice channels to check it. Both eager initialization and unmute
must use that recording policy. `init_recording_on_send` means **pre-initialize**;
do not redefine it as a general ban on actual recording. When recording is enabled,
its false setting must still allow normal eventual recording start.

The existing public comment for SetRecording mentions stopping device recording,
not a guarantee against initialization. Clarify the intended no-initialization
contract with maintainers. Do not call a stronger contract already guaranteed by
all upstream versions. The SDK's custom-source extension also sends independently
of the ordinary ADM transport, so the old "no packets transmitted" comment needs
careful scope/documentation rather than a global transmission block.

`01-audio-state-draft.patch` is a deliberately small **first slice**: the
AudioState guard and an existing test strengthened to expect InitRecording0.
It does not include the policy getter/voice-channel fixes and is not the complete
external-input solution. This slice can be reviewed independently before adopting
the larger interface. Its narrow English draft is in `PR_DRAFTS.md`.

### 2. Explicit external-audio-only wrapper factory

Target `webrtc-sdk/libwebrtc`, with the .05 source snapshot
`f7e9e5904ca743066bbd8cc0e5676b7a08c48436` as the inspected baseline.
Use an immutable factory policy, not a process-global environment variable and
not a misleading per-PC switch over a shared ADM/AudioState.

Suggested public shape (proposal, not compiled API):

```cpp
struct RTCPeerConnectionFactoryOptions {
  bool external_audio_input_only = false;
};
// Keep the existing exported no-argument function unchanged.
CreateRTCPeerConnectionFactory();
// Add a new overload; do not replace the old symbol with a default argument.
CreateRTCPeerConnectionFactory(const RTCPeerConnectionFactoryOptions& options);
```

The external-only factory applies disabled recording before any PC can negotiate
or send. It creates custom sources and rejects `kMicrophone` explicitly, rather
than silently producing an empty microphone track. Ordinary default factories
retain current behavior, including mixed custom/microphone sources where supported.
A factory policy cannot promise process-wide zero capture: a separately created
ordinary factory can still open a microphone. Tracks imported from another factory
need an explicit supported/unsupported contract; source labels are not ownership.

With native policy checks at all three sites, wrapper-side manipulation of the
pre-initialization option is not the primary safety mechanism. If added as an
optimization, keep its original meaning. No playout toggle, mixer-pull export,
AEC algorithm, WASAPI workaround or audit counter belongs in this feature PR.

## Submission gates

- Compile the exact native and wrapper patches on the chosen upstream base.
- Run AudioState tests: disabled add/remove/re-add gives Init0/Start0; enabled
  preserves behavior; disable→enable initializes/starts normally.
- Run voice-channel tests for eager send and mute/unmute with recording disabled.
- Preserve init_recording_on_send=false behavior when recording is enabled.
- Test external PCM through actual received/decoded media with no capture calls;
  the stock lab's decoder failure is not a substitute for this regression test.
- Test ordinary getUserMedia and normal capture/playout unchanged.
- Test multiple PCs in one external-only factory and coexistence with a separate
  ordinary factory, including lifecycle/track-replacement/mixed-source contracts.
- Verify old exported factory symbol/import linkage and default source behavior.
- On Windows rerun independent ETW controls: record client1, SDK capture0, no
  observation loss, continuous external capture and real received PCM.
- Keep the test instrumentation out of the production diff. Avoid unrelated
  dependency updates and the separate render-initialization failure.

The full unmute policy/API patches and the native regression/build gates above
remain future work. Maintainer acceptance and release timing are unknown. Neither
an issue nor a PR has been sent as part of the preparation/value assessment.

## Check the included draft

```sh
python3 tools/check_upstream_proposal.py
```

This fetches two pinned source files into a temporary directory, validates hashes,
and checks/applies the first patch there. It does not modify a shared checkout,
build an SDK, run native unit tests, or contact maintainers. Source provenance and
status are in `source-inputs.json`.

The wrapper README currently contains an older m144 build example; use explicit
release/source pins rather than silently applying those instructions to m150.
No CONTRIBUTING.md or PR template was found at the inspected raw paths; this is
not a claim that the projects have no contribution requirements. Check the actual
submission target again when implementation/testing is ready.
