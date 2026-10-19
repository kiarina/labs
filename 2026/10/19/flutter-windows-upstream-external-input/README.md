# Native Flutter validation of proposed upstream external-input support

**Capture isolation passes on the measured Windows setup.** The candidate keeps
one continuous record/MF client and zero extra SDK capture attempts. Actual
received PCM/video also passes with the separate native-playout diagnostic.
Official SDK availability, public wrapper playout support and speaker/AEC remain
unfinished. No upstream PR has been submitted. This lab builds a candidate
SDK, not an unmodified official SDK, and cannot demonstrate official availability.

Question: can the three-path recording policy plus an immutable external-only
factory keep one continuous record capture, eliminate additional SDK capture,
and deliver real decoded audio/video through native flutter_webrtc?

Controls use the same candidate DLL and app: record-only, native microphone with
the default factory, then continuous external PCM with the external-only factory.
Collect loss-free Windows Audio Client ETW with validated caller stacks before
launch. Zero observed clients alone is inconclusive. Require positive capture
coverage, matching DLL identity, continuous capture, and received decoded PCM.
Report capture isolation separately from audio render/decoder failures. Video
may be explicitly synthetic; this does not establish physical-camera support.
Synthetic mode does not recheck physical-device availability; its older recorded
"unavailable" app label must not be interpreted as a new hardware observation.
No microphone PCM or private ETL is committed.

Inputs remain Flutter3.47.2/Dart3.13.2, flutter_webrtc1.6.2+hotfix.4, record7.1.2
(record_windows2.3.0), and the copied lockfile to isolate the SDK/policy change.
Candidate core is webrtc-sdk/webrtc@51c367e209f8f12b39bd8dd0ca70bf588f42cb48;
wrapper is webrtc-sdk/libwebrtc@f7e9e5904ca743066bbd8cc0e5676b7a08c48436.
The SDK must be built from those inputs plus `sdk/core-policy.patch` and
`sdk/factory-policy.patch`;
record actual patch and DLL hashes before running. No lab audit/playout exports
or global device/volume changes belong in the candidate SDK.

Predecessor: [official-SDK negative experiment and upstream kit](../flutter-windows-stock-sdk-external-capture/README.md).
This lab owns its app, bridge and observer copies and does not import predecessor code.

## Prepare and build

Run `python3 tools/prepare.py` once in a fresh lab. It downloads the pinned Flutter
plugin and adds the Windows initialize option `externalAudioInputOnly`. The
factory mode is immutable; native repeated initialization and explicit Dart mode
changes are rejected. Microphone getUserMedia requests are rejected in this mode.
The generated vendor copy is ignored; the shared pub cache is unchanged.

Build the pinned native checkout with a complete DEPS toolchain and the core
patch. Retain that change as a scratch commit for three-way application. Place
the pinned wrapper in `src/libwebrtc`, apply the factory patch there, then apply
its ordinary `custom_audio_source_m150.patch`, `add_libwebrtc_build_target.patch`
and `allow_176k4_192k_shared_mode_formats.patch` to the native tree with
`git apply --3way`. No lab instrumentation patch is applied.

Windows GN args: use_siso=false, use_remoteexec=false, is_debug=false,
is_clang=true, target_cpu="x64", use_custom_libcxx=false,
rtc_libvpx_build_vp9=true, enable_libaom=true, rtc_include_tests=true,
rtc_build_examples=false, rtc_build_tools=false, is_component_build=false,
rtc_enable_protobuf=false, rtc_use_h264=true, ffmpeg_branding="Chrome",
rtc_use_h265=true, symbol_level=0, enable_iterator_debugging=false.
Use the installed VS2022 toolchain (`DEPOT_TOOLS_WIN_TOOLCHAIN=0`) and the pinned
DEPS Chromium Clang. Generate `out-policy` and build targets `libwebrtc` and
`libwebrtc:libwebrtc_cpp_api_unittests`. Before applying wrapper patches, the core
regression targets are `audio_engine_tests` and `media:rtc_media_unittests`.
The preceding kit retains the core-only differential results and limitations.

Stage the DLL, import library and wrapper headers from that same build with
`tools/windows/stage_sdk.ps1 -NativeSource <native-src>`. Then run Flutter pub get
and `flutter build windows --release` from `app/`. CMake refuses to fall back to
downloading an official SDK. The result is `upstream_input_app.exe`.

Build the observer using `tools/windows/build_observer.cmd` in a VS x64 prompt.
Run `tools/windows/run_trial.ps1` from an elevated interactive desktop, providing
a fresh output directory and the SDK manifest. Use `record-only`, `native-mic`
(with ExternalOnly=false), `external` with both factory modes, and `muted` as
needed. The app checks the loaded DLL hash and rejects the old lab-specific
recording-audit and mixer-pull exports. `UPSTREAM_CAMERA_MODE=synthetic` is explicit.
The collector must start successfully before launching; never cancel someone
else's WPR session. Private trace and app outputs belong under ignored `build/`.

The candidate source copies in `sdk/` are owned by this lab; they are not implicitly
synchronized with the predecessor's initial preparation kit.

## Results

[Retained results](results/summary.json) use one candidate DLL hash
`8129e167b16e820c79a9aaadbca1676190a3b4d690b5125c24dbded91db45ed1`.
No lab-specific audit, manual mixer-pull export or interception code is compiled
into this DLL.

| Trial | Record/MF capture | SDK capture | Received PCM |
| --- | ---: | ---: | --- |
| record-only | 1 | 0 | control |
| ordinary factory / native microphone | 0 | 1 | 0; native render fails |
| ordinary factory / external PCM | 1 | 1 | 0; native render fails |
| external-only factory / external PCM | 1 | 0 | 0; native render fails |
| external-only / muted→unmuted | 1 | 0 | 0; native render fails |
| external-only / native playout off diagnostic | 1 | 0 | 238080 / 238560 samples |
| external-only / native track disable/enable twice, diagnostic | 1 | 0 | 237600 / 238560 samples |
| external-only / replaceTrack(null)→restore twice, diagnostic | 1 | 0 | 237600 / 238560 samples |

All eight traces have lostEvents0/lostBuffers0, attributed capture stacks and
unchanged endpoint volume/mute. Positive controls use the same DLL and capture
endpoint. Record starts once and raw capture/video counters advance through the
sender gates. The final trial detaches/restores the sender track with
replaceTrack(null)/replaceTrack(original) twice, without renegotiation. Audio RTP and synthetic video decode even in the native-render
failure cases; that alone is not counted as complete media flow. The successful
diagnostic cases have nonzero received RMS in both gates. These short counter/
transport tests do not establish intelligibility, latency or AEC quality; the
track-gate trial's maximum Dart raw-audio delivery gap was77.6ms.

The native render trial attempted mono192kHz/16-bit WAVEFORMATEX and failed with
internal HRESULT0x887c0030, mapped0x88890008. Windows documents an unsupported
format as an Initialize failure
([IAudioClient::Initialize](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize)).
No system format, volume or effect setting was changed to work around it.

The optional diagnostic calls the existing native SetAudioPlayout(false) before
negotiation so the standard NullAudioPoller drives reception. It adds no SDK
export or additional SDK patch. It needs exact matching native/wrapper headers
and protected-member access in the lab bridge; it is **not a supported public
wrapper API or a finished playback implementation**. Build with LAB_NATIVE_SOURCE
pointing at that exact SDK source to enable it, and select
NativePlayoutDiagnostic=true in the runner. Native headers are compiled as system
headers with C++20/NOMINMAX. Initial diagnostic builds failed on Windows macros,
external-header warnings and an ambiguous scoped_refptr; these were fixed in the
lab bridge/build settings, not by editing the SDK or removing its checks.

The [wrapper tests](results/wrapper-tests.json) pass3/3. The additional test-only
extension did not rebuild or change the SDK DLL. The
[old-binary compatibility exercise](results/abi.json) loads the candidate DLL
from a private copy of an older official05-header Flutter build: exit0, errors0,
matching DLL hash, unchanged endpoint volume/mute. This is not an official-DLL
trial or an exhaustive ABI promise. The preceding kit retains the separate
core-only60-case/310-case differential run, including178 common broad failures.

The [upstream draft](PR_DRAFTS.md) keeps the core fix, wrapper API and future
playout/AEC work separate. Core patch context is BSD-3-Clause; wrapper context
retains its upstream license (copies under sdk/). The root lab license does not
replace those upstream notices.

## Verify retained evidence

`mise run` opens no devices. It checks SDK/patch identity, positive capture
controls, media/track-gate results and old-binary observations. Negative cases
ensure a missing capture witness, lost trace, missing SDK-positive control or
wrong DLL cannot become a false zero-capture success. To regenerate the report,
use `python3 tools/assess_trials.py build/trials results/summary.json` after
collecting all eight private trials. Raw trace/app files stay ignored.

`python3 tools/check_sdk_patches.py core` and `factory` check pinned-source hashes
and patch application only, not compilation. The native runtime, unit and
compatibility observations above are separate evidence.
