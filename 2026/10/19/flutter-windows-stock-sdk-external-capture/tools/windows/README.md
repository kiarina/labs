# Stock-DLL capture observation

Build `build_observer.cmd` from a VS x64 Native Tools prompt (or pass the
`vcvars64.bat` path). This creates separate observer/control EXEs. It does not
modify or inject code into the application or SDK. WPR/xperf/tracerpt and the
Windows SDK ETW headers/libraries were already installed for the measurement.

`mic-control.exe` opens the default console capture endpoint for two seconds,
initializes/starts shared-mode WASAPI, discards captured frames, then stops and
releases COM references. It saves no PCM. Calibration establishes direct WASAPI
event/stack visibility; it does not establish DMO or WebRTC visibility by itself.

From an elevated **interactive desktop** PowerShell, use a fresh output directory:

```powershell
./collect.ps1 -Executable ./build/mic-control.exe -OutputDirectory ./build/control-1
```

For app trials, build the parent app in a separate scratch using only the
published vendor SDK. Preserve the complete Release directory. Set `STOCK_VARIANT`,
`STOCK_MIC`, `STOCK_CAMERA_MODE`, `STOCK_EXPECTED_SHA256`, `STOCK_EXIT` as described
in the root README, then pass `stock_capture_app.exe` to this collector. Run each
variant as a new process with trace enabled **before** launch. Use record-only,
source-only, native-mic positive control, then external; the tested SDK must have
exactly its published DLL hash. Never copy the earlier lab's custom DLL.

The profile enables the stock Windows Audio Client TraceLogging provider with
synchronous user stacks plus kernel process/image-load events. Buffers total
12MiB (4MiB system +8MiB provider); file-mode growth is separate. No CPU sampling
or PCM capture is enabled. The provider GUID was identified through the built-in
WPR Audio profile, then its direct capture events and caller frames were validated.

Private outputs: trace.etl, events.csv, raw stacks, process logs. Normalization
replaces endpoint IDs with SHA256 and resolves addresses to module basename+RVA.
Unresolved frames stay explicit. Check trace-stats.txt: lost events and buffers
must both be zero. Check Initialize/Start HRESULT, capture StreamType1,
AudioClientGuidId and endpoint identity. Multiple lifecycle events for one client
are not multiple clients. Match stack/module attribution with positive controls.

A capture event with a WebRTC-owned caller stack is evidence of extra OS capture.
A DMO object being created is not sufficient. A server-only stack lacking the SDK,
missing events/stacks, or unvalidated DMO coverage cannot prove zero capture.
There is no blocking/hooking/fake-success behavior in these tools.

Interactive tasks may be used to launch the collector from SSH: use dedicated
names and `schtasks /create ... /it /rl HIGHEST` with an action script that sets
working directory/env and invokes collect.ps1. After completion remove only these
dedicated tasks; verify the app/control is gone and WPR is not recording. Never
cancel another task's tracing session. Keep private artifacts out of Git.

Schema/reference: Microsoft [WPR EventProvider](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/eventprovider)
(`Stack=true`) and [Core Audio stream management](https://learn.microsoft.com/en-us/windows/win32/coreaudio/stream-management).

The first record-only CSV export was interrupted by PowerShell's treatment of
native xperf diagnostic output. The original ETL was intact and had zero lost
events/buffers; re-exporting that same ETL recovered complete payloads/stacks
without another capture. The collector now waits for xperf via Start-Process
and separately redirects diagnostics. Partial CSV files must never be interpreted
as zero observed capture.

Use `build_app.ps1 -LabRoot <private-copy>` to build the app. For an SDK05
comparison use a separate private source/vendor/build tree; run `prepare_sdk.ps1`
there with the official05 archive and `-Version 05` **before** building, so the
INI, headers, import library and deployed DLL match. This is a configuration
change to a private vendor copy, not an SDK rebuild. Never drop a newer DLL into
a binary compiled against different headers and claim a matched build.

`invoke_trial.ps1` sets explicit variant/SDK identity and environment values,
checks the deployed DLL against official-sdks.json, then invokes the collector.
It supports public playout selection, receiver-track gain, and public
AudioOptions-off controls; none is an OS-global volume operation. Capture/render
volume and mute are read-only snapshots before and after each trial. Supply SDK
versions as strings (`'03'`, `'05'`); numeric PowerShell literals lose leading zero.
A setup run accidentally parsed05 as5 and therefore used the03 DLL; its actual
hash identified it as an03 repeat, and it is excluded from05 comparisons.

Measured setup failures are retained separately from functional trials. The
public playout-device call initially failed compilation because MSVC treated
implicit int-to-uint16_t conversions as errors; explicit casts fixed the app
plugin without modifying the SDK. The mis-tagged05 setup attempt actually
loaded the verified03 DLL, is retained as an03 repeat, and is excluded from05
results. `results/observation-calibration.json` also records the muted control's
trace-start UTC + CSV-relative timestamps + app-unmute UTC derivation: SDK
capture started approximately2.49 seconds before unmute.

The05 measurement uses a fresh lab05 source/vendor/build copy. Its private vendor
INI is set to libwebrtc.m150.7871.05, and its header tree, import library and DLL
are extracted from the same official ZIP by prepare_sdk.ps1. Flutter pub get and
release build run in that independent tree. The deployed DLL is hashed again
before launch; no runtime copy from a custom SDK and no ABI/layout patch is used.

Final collection cleanup verified WPR was not recording and no experiment/control
or parser EXE remained. Dedicated stock build03/build05/run tasks were deleted.
Both official SDK hashes and the earlier lab's separate SDK-cache hashes were
unchanged. Private ETL/CSV and scratch build caches are retained for reanalysis;
no microphone samples or video frames were saved by this experiment. All measured
before/after endpoint volume/mute snapshots matched. Receiver track gain is
reported separately from OS endpoint gain.
