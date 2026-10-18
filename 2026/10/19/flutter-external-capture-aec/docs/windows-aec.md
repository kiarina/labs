# Windows speaker/AEC path

`app/lib/windows_aec_probe.dart` exercises one continuously running `record`
PCM16 mono 48 kHz stream, the standalone AEC3 engine, two gated cleaned-audio
WebRTC connections, and a separate received-far connection. Video is a continuous
synthetic BGRA fixture: the test machine has no usable physical camera.

`aec_audio/windows/windows_playout.cpp` opens only a WASAPI render endpoint. It
uses the actual shared-mode mix format, resamples from mono 48 kHz and upmixes to
all endpoint channels. A 10 ms event-driven render thread clocks the decoder.
After a successful `ReleaseBuffer`, the exact submitted post-gain PCM enters
AEC reverse processing and a bounded 120-second trace. Capture processing uses
the same independent DSP handle. `IAudioClock` supplies actual device progress;
queue insertion alone is not counted as physical playback.

The test uses an audited, recording-isolated SDK from this lab's
`patches/windows` bootstrap. Extend its completed object cache into another
output directory, without modifying the cache:

```powershell
python tools/windows/extend_transport.py --sdk-root $SdkCache --output $AecSdk
python tools/prepare.py
python tools/prepare_aec.py
cd app
flutter pub get
flutter build windows --release -t lib/windows_aec_probe.dart
Copy-Item "$AecSdk/libwebrtc.dll" build/windows/x64/runner/Release/libwebrtc.dll
$env:EXTERNAL_EXIT='true'
$env:EXTERNAL_CAPTURE_RECORDING_CONTROL='0'
./build/windows/x64/runner/Release/external_aec_app.exe
```

The SDK extension exports `LabPullPlayout`. It calls the pinned SDK's
`AudioTransportImpl::NeedMorePlayData` for mono 480-sample blocks. Native default
playout and `AudioState`'s silent null poller are disabled in protected mode, so
WASAPI supplies the sole decoder pull clock. Without disabling the null poller,
decoding would advance twice per physical period. The SDK's recording audit
remains active; recording init/start counters must remain zero throughout.
`results/windows-manual-playout-sdk.json` records the source pins, input/output
DLL hashes and generated-source hashes.

During acoustic phases, a known local far fixture plays from the render queue.
During the two near-end transport gates, decoded receiver audio is pulled and
discarded to avoid feeding the same local microphone back into its own speaker.
The final received-far phase sends a separate device-free custom source through
Opus/RTP and the native receiver mixer into WASAPI and the same AEC reference.
It verifies received packets/samples and device-clock movement. The acoustic
analysis separately measures the actual speaker echo using the render trace.

Output `%TEMP%/aec_*.pcm` and `aec_result.json` are local artifacts. Copy them to
an ignored build directory, rename them to the analyzer's `raw.pcm`, `clean.pcm`,
`mixed.pcm`, `near.pcm`, `reference.pcm`, `actual_render.pcm`, `report.json`, then
run `tools/analyze_acoustics.py`. Only its metrics JSON belongs in
`results/`. Near-end fixtures are added only to capture, never to the speaker;
this verifies signal retention without claiming a real human speech quality test.

The first run's trace-dispatch error is retained as
`results/windows-first-run-trace-error.json`; it is not an acoustic pass.

## Measured result

`results/windows-acoustic.json` contains a complete 68.9-second run with one
microphone start, no physical camera start, two successful send gates and a
successful received-far path. The endpoint was stereo float32 at 96 kHz; the
48 kHz DSP/reference stream was resampled for the actual endpoint. Maximum
capture/video gaps were 50.9/55.3 ms. The seven recording-device audit counters
remained zero across all six peer connections, all six protected. DSP errors,
manual decoder pull failures and render-trace overflow were zero.

Actual-render matched echo reduction was 11.18 dB for far-1, 7.59 dB after
restart, and 8.07 dB for the received Opus/RTP far fixture. Near gain was -0.205 dB
and double-talk near gain -0.208 dB. Double-talk echo reduction was only 1.29 dB,
with weak raw/render correlations (.04–.12 in those phases). This is limited
physical evidence, not a double-talk suppression pass. Device/speaker/microphone
placement and nonlinearity were not controlled in this short measurement.

`results/windows-digital.json` uses the same built Windows engine DLL with the
deterministic 18-second-per-case device-free probe. It passes: far-only 61.43 dB,
near correlation .9609/gain .9452, and double-talk near gain .5560 with correlated
echo improvement 36.20 dB. This validates the Windows build and MSVC portability
edits separately from the physical acoustic path.

A repeated projection search with a ±500 ms window is saved in
`results/windows-acoustic-wide-search.json`. Double-talk, far-2 and received-far
retain the same internal peaks (raw lag 6213, cleaned lag 6643 samples), so their
weak correlations are not caused by the original ±50 ms window boundary.
Far-1/warmup select different chirp aliases with essentially equal correlation.
The broader search does not strengthen the physical double-talk claim.
