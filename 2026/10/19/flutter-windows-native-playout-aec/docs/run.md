# Reproduce the Windows fixture

This lab requires the candidate native SDK; it does not demonstrate this with an official unmodified SDK. Use core [#314](https://github.com/webrtc-sdk/webrtc/pull/314), commit543b9cb, and wrapper [#158](https://github.com/webrtc-sdk/libwebrtc/pull/158), commitf9a23f9, with their documented native build prerequisites. The tested DLL hash is73b672f90beba282e04ae6dd9dbcb7b3af574d192977ae9224c382075dbcd740. Preserve matching import library and headers. A rebuild can have a different identity and needs fresh validation.

Run from this lab directory with Python3.12, Flutter/Dart matching the lockfile (Dart3.13.2), Visual Studio2022 C++ and Windows Performance Toolkit. Keep all output in ignored `build/`. Package pins intentionally isolate this experiment: record7.1.2, record_windows2.3.0 (lab RAW fork), flutter_webrtc1.6.2+hotfix.4, camera0.12.1/camera_desktop2.0.0. The Windows app currently generates synthetic video; it does not open a physical camera.

Prepare the shared fixture first from the repository root with `mise run //:test-assets:download`. Then:

```sh
python tools/prepare.py
python tools/prepare_record.py
python tools/prepare_aec.py
python tools/prepare_speech.py
```

`prepare.py` requires a fresh vendor directory. It adds the external-only factory option and prevents implicit SDK downloads. RAW capture is an opt-in, lab-local record_windows fork, not the published package's behavior. RAW failure must not silently fall back to Media Foundation. Firmware/driver processing is not proven absent.

From an elevated interactive Windows developer terminal:

```powershell
./tools/windows/stage_sdk.ps1 -NativeSource $env:LAB_NATIVE_SOURCE
cd app
flutter pub get
flutter build windows --release
cd ..
./tools/windows/build_observer.cmd
```

The source-matched native source environment variable enables an inherited optional diagnostic compilation path. Normal experiments do not call that diagnostic or disable native playout. It is optional for normal-render builds. The AEC plugin itself depends only on standalone AEC3, Flutter and Windows audio APIs.

Start the independent peer on another machine in the same LAN, with no STUN/TURN or cloud service:

```sh
python -m venv build/peer-venv
build/peer-venv/bin/python -m pip install -r requirements-peer.txt
build/peer-venv/bin/python tools/peer.py --speech app/assets/far_speech.pcm --output build/peer --port 18794
```

HTTP signaling binds localhost. Use an SSH reverse forward or an equivalent private signaling route to expose that localhost service to the Windows app; ICE/RTP must also be reachable over LAN. Pass its Windows-side URL with `-Peer`. The peer sends the far fixture at gain2 and saves decoded near PCM without speaker playback. Do not listen to saved clips during an acoustic run.

The public output selector chooses the fixture's EDIFIER speaker **after** media PeerConnection creation, before negotiation. Adapt the explicit speaker label in the source for other hardware and record the change. Microphone picker selection persists in a private temporary file; `-MicrophoneId` overrides it. Defaults are not portable device preferences.

```powershell
./tools/windows/run_trial.ps1 -Session control -OutputDirectory build/control -SdkManifest build/sdk-manifest.json -PositiveControl
./tools/windows/run_trial.ps1 -Session low-near -OutputDirectory build/low-near -SdkManifest build/sdk-manifest.json -Output conditioned -NearGain 0.05
./tools/windows/run_trial.ps1 -Session human -OutputDirectory build/human -SdkManifest build/sdk-manifest.json -Output conditioned -Human
```

Use a fresh output directory and one process per trial. Human mode waits for the participant to explicitly select the input and press Start on every run (unless `-MicrophoneId` supplies an explicit input). Immediately read the microphone-check cue aloud. Then stop speaking, press the quiet-measurement confirmation and remain silent/still for8seconds; the final4seconds define the quiet level. Follow near/far/double-talk cues afterwards (about90seconds plus the manual confirmation). A failed microphone check aborts rather than counting silence as successful human speech. Baseline remains the default. `headroom` is an opt-in live profile with capture gain0.5/postgain1; `conditioned` is the separate8x opt-in candidate restricted to low inputs. Its fixed8x pre-AEC gain is reversed after processing. Human conditioned mode aborts after microphone-check if overrange has already occurred. Any later nonzero `conditionedOverrangeSamples` still invalidates the low-input headroom condition; this is not a general AGC or a large-input solution.

The collector refuses an existing WPR session and stops only its own trace. ETL, endpoint IDs, raw JSON, PCM and listening files stay private/ignored. Public ownership metrics distinguish physical microphone capture from render LOOPBACK. A positive control must produce SDK microphone events with no lost events/buffers before treating zero observed events as evidence.

Analyze with `requirements-analysis.txt` installed:

```sh
python tools/ownership.py build/low-near results/low-near-ownership.json
python tools/analyze.py build/low-near results/low-near.json
python tools/near_windows.py build/low-near/artifacts results/low-near-windows.json
python tools/diagnose_dropouts.py build/human/artifacts build/peer/human-received.pcm results/human-dropouts.json --variant conditioned
python tools/listening.py build/human/artifacts/report.json build/peer/human-received.pcm build/human/listening --max-gain 32
```

Listen to `doubletalk-1.wav` and `doubletalk-2.wav` separately. The legacy combined doubletalk file has an edit at6seconds. Listening gain is not transmission gain or normal-volume usability evidence.

For deterministic device-free checks/replay:

```sh
cmake -S native -B build/aec -DAEC_BUILD_PROBE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/aec --config Release
# executable location depends on the CMake generator
build/aec/aec_digital_probe 18 0.05
build/aec/aec_replay_events build/low-near/artifacts/mixed.pcm build/low-near/artifacts/actual_render.pcm build/low-near/artifacts/dsp-events.bin 18 build/replayed.pcm 20
```

On Windows use the matching recorded AEC DLL and compare replay hashes. The serialized event log records reverse/capture processing order under one mutex. The reference thread is stopped before snapshots; capture and reference input counts must agree with the log. The earlier human-2 lacks this event log: `replay_dropouts.py` approximates cadence and is exploratory only.

After each experiment, check record shutdown active0/HRESULT0, WPR stopped and no application left capturing. Stop the owned peer/signaling forward and remove any temporary launcher task. Keep private artifacts for analysis; never cancel unrelated WPR sessions or delete shared SDK caches.

For the saved-input headroom experiment, prepare a fresh scaled PCM and replay the original serialized event order with baseline preset0. Keep post-gain at1; multiplying by2 afterwards would discard the intended output headroom.

```sh
python tools/prepare_headroom.py build/human/artifacts/mixed.pcm build/half-input.pcm --scale 0.5
build/aec/aec_replay_events build/half-input.pcm build/human/artifacts/actual_render.pcm build/human/artifacts/dsp-events.bin 0 build/half-output.pcm 20
```

This is device-free DSP replay, not new live acquisition or decoded delivery evidence. The recorded experiment uses the same Windows AEC DLL for live and replay; check the reported identities before making that claim.

For a live headroom trial use `-Output headroom` and an explicit DualSense input ID. The app stores baseline and headroom PCM from the same input; only headroom is sent. Run the ordinary analyzer first, then the gain-aware paired decision (the raw analyzer reports actual output gains):

```sh
python tools/analyze.py build/headroom results/headroom.json
python tools/analyze_headroom.py build/headroom results/headroom.json build/peer/headroom-received.pcm results/headroom-paired.json
python tools/near_windows.py build/headroom/artifacts results/headroom-windows.json --candidate headroom
python tools/diagnose_dropouts.py build/headroom/artifacts build/peer/headroom-received.pcm results/headroom-delivery.json --variant headroom
```

Echo and known-near transfer are normalized for expected0.5 **in analysis only**. Actual sent/received audio stays attenuated; exact full-scale counts are taken before any listening normalization. Baseline remains the default if paired non-regression or participant quality fails.
