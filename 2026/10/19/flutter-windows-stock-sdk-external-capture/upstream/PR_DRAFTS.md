# English PR drafts

These are preparation text, not submitted PRs. Do not report unrun tests as passed.

## First native slice

**Title:** Avoid initializing ADM in AudioState when recording is disabled

### Problem

`AudioState::AddSendingStream()` calls `InitRecording()` even after
`SetRecording(false)`. Only `StartRecording()` is currently conditional.
On Windows, initialization can acquire capture resources; disabling recording
therefore does not consistently avoid those resources when a send stream is added.

### Change

Guard initialization with the recording-enabled state and strengthen
`AddStreamDoesNothingIfRecordingDisabled` to expect both InitRecording0 and
StartRecording0. Default recording-enabled behavior is unchanged.

This patch intentionally addresses only the AudioState branch. Voice-channel
eager initialization/unmute and an external-only wrapper API are separate work;
this is not a claim that the full external-input use case is fixed.

### Validation status

- Pinned native source hashes and patch applicability: checked.
- Native compilation and `AudioStateTest` execution: **not run yet**.
- Full external-input hardware validation of this patch: **not run yet**.

The existing stock-SDK lab independently observes additional SDK capture, but
that is problem evidence, not validation of this patch. Maintainers should also
confirm the intended initialization contract of disabled recording.

## Dependent wrapper feature (design draft only)

**Title:** Add an opt-in external-audio-only peer-connection factory

Applications supplying PCM through `kCustom` currently still cause the default
ADM to acquire a microphone. The attached stock-SDK reproduction distinguishes
record-only/source-only controls from active sending with an additional SDK
capture client, using unmodified official binaries and independent ETW stacks.

Propose an immutable external-only factory option, default off, preserving the
old no-argument factory export. External-only factories disable physical recording
before negotiation and reject microphone-source creation. Ordinary factories keep
their current behavior. The policy is factory-scoped because PCs share AudioState;
it does not disable microphones belonging to a separate factory.

This feature depends on consistent native recording-disabled checks in send
setup, stream registration and unmute. It does not overload the pre-initialization
flag's semantics. Playout, AEC algorithms, lab counters and environment controls
are excluded. Mixed/imported tracks need a defined contract and tests.

**Status:** API proposal only. No complete implementation/build/regression result
exists yet. Required tests and ABI checks are listed in the preparation README.
