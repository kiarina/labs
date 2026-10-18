# Windows recording ownership: lab-only native SDK

## Question and acceptance criteria (defined before execution)

Keep `record` as the only physical microphone capture path while injecting its
PCM into normal WebRTC audio tracks. The lab must keep acquiring source data
through idle → send → idle → send → idle, receive nonzero decoded PCM in an
independent Chrome receiver, and demonstrate that WebRTC never enters its
physical recording initialization paths.

The existing prebuilt SDK exposes no recording toggle. The native
`PeerConnectionInterface::SetAudioRecording(false)` is available inside the
wrapper, but calling it alone is insufficient: `AudioState::AddSendingStream`
initializes recording before consulting its recording-enabled flag, and
`WebRtcVoiceSendChannel::SetSend` has a separate eager initialization path.
The wrapper and native guards must cover both initialization and start.

## Implementation

- Builds the pinned native WebRTC and libwebrtc wrapper in a dedicated build
  directory; do not modify a pub cache or shared SDK installation.
- Disables native recording immediately after each peer connection is created,
  before tracks or SDP are applied.
- Guards the native eager-recording paths while retaining custom PCM delivery
  and the existing playback/decoding paths.
- Exports nine atomic counters from the same DLL that contains WebRTC. Observe
  the loaded module's SHA256, not merely a build-directory artifact.
- `EXTERNAL_CAPTURE_RECORDING_CONTROL=1` restores ordinary recording behavior
  in the same audited DLL for a positive control. This is a lab-only switch.

The SDK variant is dedicated to external input: normal WebRTC microphone
capture is disabled in protected mode. Production packaging and a general
multi-input SDK API are outside this experiment.

## Execution matrix

1. Audited DLL + positive control: the recording path must reach ADM and
   Windows recording initialization, and either direct WASAPI initialization
   or the AEC DMO capture initialization route. The machine's known playback
   format failure may still prevent actual native recording from starting.
2. The identical DLL + protected mode: all seven recording/backend counters
   must remain zero, while the peer/suppressed-peer counts match and are
   nonzero. `record` input and decoded remote media must continue in both send
   phases. All idle phases must continue capture without injection.

The source stream verification reuses `tools/verify_results.py` (minimum
source rates, maximum 500 ms source callback gap, received PCM energy and
received/decoded RTP samples/frames). The independent audit verifier is:

```sh
python3 tools/verify_windows_recording_isolation.py \
  results/PROTECTED.json results/CONTROL.json
```

The verifier has nine fail-closed checks (`python3 tools/test_recording_verifier.py`): missing export evidence, an extra capture call, a different DLL, an unexercised control, synthetic-only input, a non-independent receiver, silent received media, and decoded concealment samples without new received audio RTP bytes are rejected. The positive unit case uses constructed counters and is not runtime isolation evidence.

Audit keys, in native export order:

| Counter | Meaning |
| --- | --- |
| `admInitRecording` | Entry to ADM recording initialization |
| `admStartRecording` | Entry to ADM recording start |
| `windowsInitRecording` | Entry to Windows backend recording initialization |
| `windowsStartRecording` | Entry to Windows backend recording start |
| `wasapiInitialize` | Direct capture `IAudioClient::Initialize` call site |
| `wasapiCaptureService` | Direct capture `IAudioCaptureClient` service acquisition |
| `dmoInitRecording` | AEC DMO capture initialization |
| `peerConnections` | Native peers created |
| `suppressedPeerConnections` | Peers that disabled native recording before media setup |

The positive control demonstrates detection of capture initialization attempts;
its counters are incremented before the call's result is known. It does not
prove that the native capture stream successfully opened on this machine.
Protected-mode success requires those entry counters to remain zero.

This guard is scoped to the pinned lab workflow. It does not establish a general
SDK guarantee for callers that explicitly re-enable native recording, replace
the audio device, or change native call paths after this experiment.

The backend counters measure WebRTC's DLL only. `record_windows` has its own
capture implementation, so the application's expected microphone access is
not miscounted as WebRTC access. Missing audit exports are errors, not zeros.

## Results

**PASS on Windows 11 x64.** One real `record` microphone capture remains open
across idle → send → idle → send → idle. Video input is synthetic BGRA;
this result does not validate physical camera capture.

The same loaded DLL was used for both runs:
`c72ef464c608b0f01ae928964b732c0bc80dbd5ba5d45b42228108f55adc2891`.
The protected run enters none of the audited recording initialization/start
paths. The control reaches ADM and Windows capture initialization, including
the DMO route. These are attempted-call counters, not success HRESULTs.

| Counter | Protected | Control |
| --- | --- | --- |
| `admInitRecording` | 0 | 2 |
| `admStartRecording` | 0 | 2 |
| `dmoInitRecording` | 0 | 1 |
| `peerConnections` | 1 | 1 |
| `suppressedPeerConnections` | 1 | 0 |
| `wasapiCaptureService` | 0 | 0 |
| `wasapiInitialize` | 0 | 0 |
| `windowsInitRecording` | 0 | 1 |
| `windowsStartRecording` | 0 | 2 |

Protected send cycles receive 294,240 / 297,600 decoded audio samples and
150 / 143 decoded video frames. Actual received audio RTP bytes increase
23,957 / 24,218, with WebAudio RMS maxima 0.03856 / 0.02823. Maximum source
callback gaps are audio 53 ms and video 46 ms; idle injection remains zero.
The audit snapshot is read after closing and disposing the peer and bridge.

- [Protected run](results/windows-recording-protected.json)
- [Same-DLL positive control](results/windows-recording-control.json)
- [SDK build manifest](results/windows-recording-sdk-build.json)
- [Stock SDK rejected before creating tracks](results/windows-stock-sdk-rejected.json)
- [Temporary task/process/profile cleanup](results/windows-recording-cleanup.json)

The independent verifier passes. Missing audit exports cause `unsupported_sdk`
at external track creation, preventing an accidental fallback to the stock
SDK. The prebuilt stock SDK is retained only as earlier experimental evidence.

## Build and reproduce

The native source is pinned to `51c367e209f8f12b39bd8dd0ca70bf588f42cb48`,
wrapper to `070aa6d763c16027ba53c0965107658c837a4dae`, and depot_tools to
`d38909eb68d85b91259f4bf20fe5ebcd38461bc2`. The manifest records the patch
hash and loaded-DLL hash. The SDK binary and downloaded source trees are not
committed. Use a dedicated build directory with tens of gigabytes available.

Prerequisites: Windows x64, Visual Studio 2022 C++ workload and Windows SDK,
Git, Python, Flutter 3.47.2 and Chrome. Prepare the lab-local flutter_webrtc
copy first with `python tools/prepare.py`, then `flutter pub get` in `app`.
Run the probes from an interactive desktop session, with microphone access
allowed. In PowerShell, from this lab:

```powershell
$SdkBuildRoot = Join-Path $env:USERPROFILE 'tmp/webrtc-isolation-sdk'
$LabRoot = (Get-Location).Path
powershell -NoProfile -ExecutionPolicy Bypass -File patches/windows/build_sdk.ps1 -BuildRoot $SdkBuildRoot
powershell -NoProfile -ExecutionPolicy Bypass -File patches/windows/run_probe.ps1 -LabRoot $LabRoot -SdkBuildRoot $SdkBuildRoot -Mode protected
powershell -NoProfile -ExecutionPolicy Bypass -File patches/windows/run_probe.ps1 -LabRoot $LabRoot -SdkBuildRoot $SdkBuildRoot -Mode control -SkipBuild
python tools/verify_windows_recording_isolation.py results/windows-recording-protected.json results/windows-recording-control.json
```

`-SkipSync` on `build_sdk.ps1` resumes after dependency synchronization. Pinned
source and upstream patch hashes are checked before resuming. `run_probe.ps1`
builds the Flutter app, copies the rebuilt DLL into that application's release
directory, verifies the loaded module's hash, and saves uniquely collected
per-mode results. The added audit API uses GetProcAddress, so the wrapper's
public C++ ABI remains unchanged and no new import-library API is needed.

The manifest's 155.5 s compile / 169.3 s invocation cover the **final resumed
invocation only**; earlier compilation and dependency downloads were cached.
They are not the total duration of a clean first build. The retained SDK tree
uses about 11.74 GB of logical file content (452,017 files), including a 317 MB
output directory; the DLL is 20,558,336 bytes. See the
[measured tree size](results/windows-recording-sdk-size.json). Temporary tasks,
probe processes and Chrome profiles were removed; source/build caches remain
available for resuming the experiment.


## Build observations

- The pinned depot_tools batch wrappers expected Python bootstrap state that
  was not generated in this environment. The build uses the GN/Ninja binaries
  and Python downloaded by the pinned native source dependencies directly.
- GN arguments are written to `args.gn`, avoiding PowerShell's handling of
  embedded quotes in native command-line arguments.
- The wrapper declares test targets unconditionally, so GN requires
  `rtc_include_tests=true`; Ninja still builds only `libwebrtc`, with no test
  execution or test-resource download.
- Chromium rejected the first audit implementation's C-array/pointer-output
  operations under its unsafe-buffer checks. The final audit uses `std::array`
  and returns one counter value per C API call, without disabling the check.
- A shallow build-tools checkout produced `LASTCHANGE.committime=0`, which
  generated a negative PE linker timestamp and stopped the first `protoc.exe`
  link. The build must use the pinned build repository's actual commit time
  rather than the zero fallback. This is a build metadata failure, not a
  recording-isolation result.
