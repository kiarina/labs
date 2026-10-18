# Windows build and capture trials

Use a dedicated working copy of this lab on an interactive Windows desktop.
The experiment uses the default console render endpoint and an explicitly
selected `record` input endpoint. Keep speaker placement, endpoint selection,
volume and OS audio effects fixed across comparisons. Do not run acoustic tests
on another machine in the same room simultaneously.

## Dependencies and audited SDK

Install the usual Flutter Windows desktop prerequisites (Visual Studio C++
Desktop workload, CMake and Windows SDK) before the experiment. The measured
build used Flutter 3.47.2 / Dart 3.13.2 and Visual Studio 2022 on Windows11 x64.
Dependency versions are pinned by the application lockfile and lab preparation
scripts. The published `record_windows` version is 2.3.0; the optional local
fork preserves the Dart record API.

Use an existing audited SDK object cache or bootstrap it using
`patches/windows/build_sdk.ps1`. The cache must match native WebRTC commit
`51c367e209f8f12b39bd8dd0ca70bf588f42cb48` and wrapper commit
`070aa6d763c16027ba53c0965107658c837a4dae`. Its baseline DLL SHA256 is
`c72ef464c608b0f01ae928964b732c0bc80dbd5ba5d45b42228108f55adc2891`.
Never modify a shared SDK cache or pub cache in place. Extend the audited SDK
into a separate output directory:

```powershell
python tools/windows/extend_transport.py --sdk-root $SdkCache --output $AecSdk
```

The measured extended `libwebrtc.dll` SHA256 is
`8bd87dc99da82852cf1da6361aa0fbe970172894c07c1c8048f213e601365168`.
Its `LabPullPlayout` export allows the render-only WASAPI thread to clock
received audio; `ExternalCaptureGetRecordingAudit` checks that WebRTC never
initializes or starts another recording device. The default native playout and
null poller are disabled in protected mode so only one decoder clock runs.
`results/windows-manual-playout-sdk.json` records the extension manifest.

## Prepare and build

Run preparation in the dedicated lab copy. Ensure Python3 is available under
the name used by `tools/prepare.py` (its Android patch subprocess uses python3).

```powershell
python tools/prepare.py
python tools/prepare_aec.py
python tools/prepare_record.py
cd app
flutter pub get
flutter build windows --release -t lib/doubletalk_probe.dart
$Release = Join-Path (Get-Location) 'build/windows/x64/runner/Release'
Copy-Item "$AecSdk/libwebrtc.dll" "$Release/libwebrtc.dll"
Get-FileHash "$Release/libwebrtc.dll" -Algorithm SHA256
```

Prepare the speech asset in a full labs checkout with FFmpeg and the shared
assets downloaded (`mise run //:test-assets:download`), then run
`python tools/prepare_speech.py`. This preparation may run on the source machine
before copying the lab to Windows. A standalone Windows working copy can use
the resulting PCM after verifying its hash; it need not install FFmpeg or fetch
the asset again. The pinned speech input and normalized PCM hash are recorded in
`results/speech-fixture.json`. The generated asset `app/assets/far_speech.pcm`
is ignored and must be copied explicitly when transferring a prepared lab.
Copying tracked files alone is insufficient. The app's pubspec declares this
asset and overrides `flutter_webrtc` and `record_windows` to lab-local vendor
paths. Generated `aec_engine.dll` is bundled beside the executable by CMake;
retain the complete Release directory, including plugin DLLs and data assets.

## Run MF control or RAW branch

Run inside the logged-in interactive desktop session so capture/render devices
and permissions belong to that user. A remote noninteractive service or SSH
session is not equivalent. From that desktop, launch the executable directly,
or use a dedicated interactive scheduled task (`schtasks /create ... /it`)
whose action is a small script containing the environment and working directory.
Do not replace or reuse unrelated tasks.

```powershell
$env:EXTERNAL_EXIT='true'
$env:EXTERNAL_CAPTURE_RECORDING_CONTROL='0'
$env:EXTERNAL_CAMERA_MODE='synthetic'
$env:EXTERNAL_MIC='DualSense'
$env:EXTERNAL_FIXTURE='speech'
$env:EXTERNAL_OUTPUT='longRefined120'
$env:EXTERNAL_FAR_GAIN='2' # final fresh trial6; trials1-5 used1
$env:AEC_RECORD_RAW='0' # Media Foundation control
& "$Release/external_aec_app.exe"
```

`EXTERNAL_MIC` is a label substring; the app resolves a matching input device
and passes its explicit ID to `record.startStream`. Record the selected label
in each result. Synthetic video is explicit because the measured machine had no
usable physical camera. It does not establish physical camera compatibility.
The final trial6 uses gain2 to improve raw/reference identifiability; this
application-only change is separate from the DSP comparison. For a matched RAW
versus MF capture comparison, keep this gain equal in both.
For a RAW trial change only `AEC_RECORD_RAW` to `1`, keeping the chosen DSP,
fixture, endpoint and volume fixed. RAW is restricted to PCM16 mono48k stream
capture; pause/resume and file capture are unsupported in this lab fork.
Unsupported RAW initialization fails explicitly; do not fall back to MF and
label the run RAW. Neither path changes global OS volume or effects settings.

## Evidence and collection

Each completed run writes `%TEMP%/aec_result.json` and `aec_*.pcm`. Copy them
immediately into a fresh ignored directory such as `build/trial-N`, before
starting another run. Rename `aec_result.json` to `report.json` and strip `aec_`
from current-run PCM filenames for the analysis tools. Old variant files can
remain in TEMP; copy only variants listed by the current app, or compare source
file timestamps. Do not mix stale candidates from earlier trials into a result.
Raw microphone PCM stays local; publish only the metrics JSON and hashes.

Every successful trial must show transport/received-far success, continuous
source acquisition, DSP/render errors zero, and all seven WebRTC recording
init/start/OS-capture counters zero. `peerConnections` must equal
`suppressedPeerConnections` and be positive. Missing audit exports are errors,
not zero measurements.

`captureStoppedStats.recordRawAudit` is sampled after `record.dispose` and
before AEC disposal. For RAW require `rawRequests=rawPropertiesAccepted=rawStarts=1`,
`nativeCaptureFrames>0`, `mfCreateRequests=0`, `lastHresult=0` and
`activeRawCaptures=0` after disposal. During acquisition active RAW captures must
be1. For MF control require RAW request/start/frame counts zero and MF creation
requests1. This proves acquisition-path ownership for the trial; RAW acceptance
does not guarantee bypass of microphone firmware processing.

An acoustic pass additionally requires the predeclared credible-reference mask,
near retention and held-out comparison criteria in the lab README. Transport
success, raw silence or reduced total RMS alone are insufficient.

After the final requested trial verify the executable has exited, remove only
the dedicated interactive build/run tasks, and recheck original SDK hashes.
Keep separate trial artifacts and failed results. Preserve reusable SDK object
caches and unrelated desktop applications; no browser profile is used by this
native probe.

## Final execution and cleanup

The final fresh trial uses RAW capture, `longRefined120`, and speech gain2.
Its reference and actual-render peaks are both 18000 PCM16 units. The collected
trial6 report records one accepted RAW start, 3,864,000 native frames, zero MF
creation requests, HRESULT0, and active RAW captures0 after disposal. All seven
WebRTC capture-init/start audit counters are0 across six protected peers. This
is acquisition/ownership evidence; the acoustic analysis determines acceptance
separately.

After collection the dedicated build/run scheduled tasks were deleted, no
experiment executable remained, and the original baseline/extended SDK DLL
hashes still matched the values above. Dedicated working copies and ignored PCM
were retained for reanalysis. No OS volume or audio-effect setting was modified.
