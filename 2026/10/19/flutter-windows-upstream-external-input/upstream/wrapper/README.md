# Wrapper PR preparation

This is the latest-main submission candidate for `webrtc-sdk/libwebrtc`.
It depends on [core PR #314](https://github.com/webrtc-sdk/webrtc/pull/314).
No wrapper fork or PR has been published.

Apply [factory-policy.patch](factory-policy.patch) to main commit
`9f6a87af46a5810a452aa20306c705b7c5269fbe`. The diff changes eight files:
two public headers, five implementation files and the existing factory test.
The core fix is a separate prerequisite, not part of this diff. Inputs,
original/patched source hashes and patch identity are in [inputs.json](inputs.json).
[PR_BODY.md](PR_BODY.md) is ready to use as a body file.

## Public API and ownership

```cpp
libwebrtc::RTCPeerConnectionFactoryOptions options;
options.external_audio_input_only = true;
auto factory = libwebrtc::LibWebRTC::CreateRTCPeerConnectionFactory(options);
if (factory.get() == nullptr || !factory->Initialize()) {
  // Handle initialization failure.
}
auto source = factory->CreateAudioSource(
    "external", libwebrtc::RTCAudioSource::SourceType::kCustom);
auto track = factory->CreateAudioTrack(source, "external-track");
```

The caller supplies captured PCM to the existing `source->CaptureFrame` API.
The option is copied at factory creation; changing the caller's options object
later does not change the factory. There is no runtime toggle. Every connection
from this factory disables native recording before it is returned to its caller.
The underlying AudioState/ADM is shared within the factory, so per-connection
mixed recording modes are unsupported. Creating microphone sources or creating
tracks from microphone sources returns nullptr in external-only mode.
Null sources return nullptr in either mode.

Sources and tracks must belong to the factory with which they are used.
Foreign microphone sources are rejected by CreateAudioTrack, but foreign custom
sources and already-created tracks passed to AddTrack/ReplaceTrack are not
fully ownership-validated. Their use is outside the supported contract; this
option is not a security boundary or a process-wide microphone block.
A separate ordinary factory may intentionally capture.

The existing no-argument factory and explicit default options preserve ordinary
capture behavior. Both exported symbols are present in the new Windows DLL;
no public virtual method or vtable slot is added by this wrapper diff.
Callers taking the overloaded function's address with `auto` must select a
signature explicitly. This is not an exhaustive source/ABI compatibility claim.
Device enumeration and device selection remain available. This option controls
capture, not playout, decoder clocks or AEC.

## Build and validation

Use the native base and core commit recorded in inputs.json, then the wrapper's
ordinary `custom_audio_source_m150.patch`, `add_libwebrtc_build_target.patch` and
`allow_176k4_192k_shared_mode_formats.patch`. Follow the parent lab's complete
[toolchain/GN instructions](../../README.md#prepare-and-build).
From the native source root with this wrapper at `libwebrtc/`:

```sh
git -C libwebrtc apply --check --whitespace=error /path/to/factory-policy.patch
git -C libwebrtc apply /path/to/factory-policy.patch
gn gen out-policy
ninja -C out-policy libwebrtc libwebrtc:libwebrtc_cpp_api_unittests
out-policy/libwebrtc_cpp_api_unittests.exe --gtest_filter=AudioDevice.*
out-policy/libwebrtc_cpp_api_unittests.exe
```

On Windows x64, GN generation, DLL build and test-target build succeeded.
[All 25 wrapper tests passed](all-tests.json), including four AudioDevice tests
([focused result](audio-device-tests.json)):

- Existing enumeration/no-argument API before and after connection creation.
- External-only microphone rejection, custom source/track creation, two
  connections, and adding/removing the custom track on both connections.
- Copied options and coexistence with an ordinary factory, including rejection
  of a foreign microphone source at CreateAudioTrack.
- Explicit default-options microphone source/track creation and null rejection.

[validation.json](validation.json) records the DLL hash, patch hash and scope.
The eight source hashes in the actual Windows build match the proposal.
A full wrapper test pass does not resolve the core suite's 178 common failures.
The native prerequisites were reused from the earlier validated core build;
core tests were not rerun for this wrapper preparation.

The earlier candidate's ETW isolation, decoded-PCM diagnostic and old-header
runtime compatibility results remain in the parent lab with their original
pins and DLL hash. Those runtime trials have not been repeated on this new DLL.
These wrapper tests do not measure microphone client counts, negotiate media,
or prove recording-policy application by themselves. Other OS builds and full
presubmit were not run. Speaker/AEC, physical camera, public wrapper playout
control and official SDK distribution remain separate work.

Run `python3 verify.py --source /path/to/pristine/libwebrtc` to check hashes,
strict patch application and retained test evidence without building or opening
devices. Omit --source to fetch only the eight pinned original files.

Before publication, recheck main, the core dependency and maintainer feedback.
If either source changes, rebase and rerun relevant builds/tests. Obtain owner
approval to create a fork and submit the prepared dependent Draft PR.
