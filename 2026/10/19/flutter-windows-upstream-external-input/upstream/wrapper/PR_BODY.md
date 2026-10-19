## Add an immutable external-audio-only factory policy

Depends on https://github.com/webrtc-sdk/webrtc/pull/314. Please review this as
a dependent change; the recording-policy core fix must ship with the wrapper.

Applications supplying already captured PCM through a custom source can still
open a second microphone client through ordinary SDK recording. Add an explicit,
factory-scoped opt-in that is copied at creation and cannot change afterward.
Apply SetAudioRecording(false) to every native connection before exposing it.
Reject microphone sources and microphone-backed track creation in this mode.

Keep the exported no-argument CreateRTCPeerConnectionFactory() and add an options
overload with external_audio_input_only=false by default. The existing API and
explicit default options retain ordinary capture. No public wrapper virtual
method or vtable slot is added. Both factory symbols are exported in the tested
Windows DLL. Taking the overloaded function's address requires selecting a
signature; this is not an exhaustive source/ABI compatibility claim.

AudioState/ADM is shared within a factory: all its connections have the same
immutable mode. A separate ordinary factory can still capture. Sources/tracks
must belong to the factory where they are used; foreign custom sources and
already-created tracks are outside the supported contract, not fully rejected
at AddTrack/ReplaceTrack. This is not a process-wide microphone block or security
boundary. Device enumeration/selection and playout are unaffected by the option.

Validation against main `9f6a87af46a5810a452aa20306c705b7c5269fbe` on Windows x64,
with native core PR #314 plus the wrapper's ordinary m150 patches:

- GN generation and targets libwebrtc and libwebrtc:libwebrtc_cpp_api_unittests
  built successfully. All 25 wrapper tests passed, zero skipped/disabled.
- Four AudioDevice tests cover legacy enumeration/no-argument use, external-only
  rejection and custom tracks added/removed on two connections, copied options
  with ordinary-factory independence and foreign microphone source rejection,
  explicit default options, and null audio-source rejection.
- The built source hashes match the eight-file proposal. Both no-argument and
  options factory exports are present.

The earlier pinned candidate has separate ETW positive-control evidence for
continuous record capture with zero SDK capture attempts, decoded PCM using a
native-playout diagnostic, and an exercised old-header runtime compatibility
check. Those runtime trials were not repeated for this latest-main DLL, and
these wrapper tests alone do not measure device acquisition or negotiate media.
Other OS builds and full presubmit were not run. Core's broader suite still
has 178 failures shared with its control; the wrapper's 25/25 is a different
suite and does not supersede that limitation.

This diff contains only the factory policy and existing-file regression tests.
Flutter integration, diagnostic internal-header access, capture-audit hooks,
mixer-pull/playout APIs, output-format workarounds and AEC are separate work.

Reproduction, exact patch/source/DLL hashes and retained test results:
https://github.com/kiarina/labs/tree/main/2026/10/19/flutter-windows-upstream-external-input/upstream/wrapper
