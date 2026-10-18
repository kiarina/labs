# Browser AEC with continuously captured record PCM

## Builtin browser comparison

For the builtin comparison, keep one `record.startStream` running with
`echoCancel: true`, disable noise
suppression and automatic gain for the comparison, and play the far-end signal
through the browser's actual output. Branch its PCM stream to analysis and
optional WebRTC injection after browser processing. This preserves the byte
stream interface; the bytes are now processed microphone PCM, not untouched
device samples. A peer connection is not inherently required to request AEC.

Inspection of `record_web` 2.1.3 shows that `initMediaStream` passes
`RecordConfig.echoCancel` directly to `getUserMedia`'s `echoCancellation`.
`adjustConfig` consults actual track settings internally, but the application
does not receive that native track through the public record API. For a
diagnostic lab, expose requested constraints, capabilities and settings through
a lab-local backend or getUserMedia observer; do not silently patch pub-cache.

The [Media Capture specification](https://w3c.github.io/mediacapture-main/)
distinguishes `false`, `true`, `"remote-only"` and `"all"`. Boolean true leaves
the precise reference selection to the browser; it must attempt remote-call
cancellation and should attempt all-output cancellation. Record's bool API
cannot express `echoCancellation: {exact: "all"}`. Required constraints can
reject acquisition. Supported settings describe configuration, not measured
acoustic suppression quality.

Chromium's [media feature implementation](https://chromium.googlesource.com/chromium/src/media/+/dc3ee4fe9d71524ea9d71ffa21261e9299c1bb2e/base/media_switches.cc)
enables Chrome-wide echo cancellation by default on supported builds. Its
reference mixes Chrome playback directed to a particular output device;
system-loopback reference is a separate feature. The [WebAudio AEC issue](https://issues.chromium.org/issues/40504498)
records desktop rollout and the later resolution, rather than a permanent
restriction to peer-connection playback. Thus arbitrary WebAudio or HTMLAudio
rendering is a reasonable desktop Chrome candidate. It still needs measurement
on the chosen browser, device and output route. An [implementation change](https://chromium.googlesource.com/chromium/src/+/39f4e893638a00bcea767cacb08c280421e00b00)
also documents that processing location and platform-AEC selection can vary.

## Selected standalone DSP path

This lab uses the same standalone WebRTC AEC3 core on native targets and Wasm
to own the render reference across all five targets. Capture remains one
`record.startStream` with builtin AEC disabled. The processor receives rendered
reference and microphone PCM. The upstream WebRTC APM
API describes the two directions; this lab wraps the smaller extracted core. Its
[public API](https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h)
accepts capture through `ProcessStream` and playback through
`ProcessReverseStream`, in approximately 10 ms frames. A concrete common
interface should use 480 samples per channel at 48 kHz, capture/render frame
timestamps, render gain/channel information, and a delay estimate. For Web,
compile a pinned processor to Wasm and bridge it to an AudioWorklet. Standard
worklet render quanta need buffering into DSP frames. Variable-size record
chunks also require an independent accumulator.

The reference must represent what actually reached the speaker path, including
applied gain, mixing and inserted underrun silence. Enqueued bytes alone are
not proof that audio played. Deliver the reference before its acoustic echo
appears in capture. Queue delay, device output latency, different capture/render
clocks, suspend/resume and output-route changes must be tracked. Keep the DSP
state alive across WebRTC send toggles; the acoustic path continues to exist.

[SpeexDSP's echo API](https://www.speex.org/docs/api/speex-api-reference/group__SpeexEchoState.html)
is a smaller native/Wasm candidate with `speex_echo_cancellation(rec, play, out)`
and split capture/playback methods. Its
[manual](https://www.speex.org/docs/manual/speex-manual.pdf)
warns that independent unsynchronized device clocks prevent adaptation;
reference alignment and clipping are also practical limits. Its internal
two-frame playback buffer is an assumption, not a measurement of browser
latency. An offline fixed-delay success cannot establish real-time acoustic
robustness. Avoid stacking standalone AEC over builtin AEC during the baseline
comparison: use `record.echoCancel: false` for the standalone mode.

## Evaluation boundary

Fake microphones, software loopback and offline synthetic echo can establish
stream continuity, format conversion and DSP arithmetic. They cannot establish
physical speaker-to-microphone AEC success. A real acoustic test must use audible
speaker output and microphone input, record device/gain/distance conditions,
and compare AEC off/on with the same far-end stimulus. Use a broadband or
speech-like far-end signal; one sinusoid gives an unrealistically easy problem.

Evaluate far-end only after convergence, near-end only with no playback, and
double talk. Report echo reduction alongside near-end level/intelligibility
preservation. Reduced output RMS by itself can mean that all speech was muted.
Uncorrelated near-end activity must survive both single talk and double talk.
No platform should be labelled acoustically validated based only on fake-device
or synthetic results.

As of this research pass, these are implementation findings and a proposed
evaluation contract, not acoustic results. Browser-specific limitations
(especially Safari/iOS, Firefox, autoplay gestures, mobile audio routes and
background execution) remain to be measured.

## Browser implementation

`tools/build_wasm.py` compiles the same `native/aec_engine.cc` and prepared
private-namespace vendor extraction into `app/web/aec_engine.js` and `.wasm`.
These are generated before the Flutter Web build. `aec_audio.js` loads this
module and maintains one C ABI handle for microphone and render processing.
`aec_playback_worklet.js` sends actual consumed PCM, including underrun zeros,
back as 480-sample references. Playback reaches `AudioContext.destination` at
48 kHz. `stopRender` waits for a queue-flush acknowledgement; it does not stop
capture or the output audio clock. Capture chunks are accumulated into 10 ms
blocks and may return an empty cleaned chunk until a full frame is available.

The prototype runs DSP on the browser main thread, serially with worklet
reference messages. A busy Flutter/UI thread can therefore delay reference and
capture delivery. It does not provide a real-time scheduling guarantee, clock
drift compensation, automatic acoustic-delay estimation, or background-tab
robustness. Statistics expose underflow and overflow rather than hiding them.
The render queue is bounded to one second; overflow drops old audio and must be
treated as an impaired run. A foreground user gesture may be needed to resume
the AudioContext. Headless autoplay flags are only for automated digital tests.

`tools/web/test_aec.mjs` calls the same Wasm C ABI directly for deterministic
digital evaluation. It uses 18 seconds per condition, measures the last three
seconds, and injects an 80 ms delayed echo at gain 0.5. Its xorshift seed,
low-pass smoothing and amplitudes are fixed in the script. The predeclared
targets are far-only ERLE at least 15 dB, near-only correlation at least 0.95
with gain within 3 dB, and double-talk near gain at least -6 dB with correlated
echo reduction at least 6 dB. Double-talk echo gain is a projection onto the
known delayed far-end after subtracting the fitted near-end; it does not measure
all residual distortion or perceptual intelligibility. Output/near correlation
is measured after selecting a fixed processing lag. These digital targets are
regression criteria, not proof of acoustic quality.

The Wasm digital run in `results/web-digital.json` passes those targets:
far-only ERLE 61.43 dB, near-only correlation 0.9609 and gain 0.9452,
double-talk near gain 0.5560 and correlated-echo reduction 36.20 dB.
The detected processing lag is 430 samples. An initial coarse lag search at
16-sample steps missed it and failed the preservation checks; that result is
retained in `results/web-digital-coarse-alignment.json`. The evaluator now
searches every sample without changing the thresholds or stimulus.

`tools/web/aec_audio_test.html` also passes a headless Chrome 155 worklet/Wasm
plumbing test (`results/web-worklet-smoke.json`): 96,000 capture samples are
processed, 95,840 nonzero render samples appear at the actual output callback,
and 232 reverse-reference frames are received without DSP errors or queue
overflow. Startup and the explicit stop period produce 15,360 underrun-zero
samples, which remain in the reference and statistics. This test feeds digital
capture; it establishes neither acoustic suppression nor physical audibility.

`renderTrace()` returns a copy of the exact PCM16 samples received from the
output callback and handed to reverse processing, including underrun zeros.
The backend retains the first 120 seconds of its lifetime, with excess samples
counted as `renderTraceDroppedSamples`. Reading does not drain the trace;
`configure` does not clear it. Retrieve before disposing the Dart wrapper.
The updated smoke test passes 13 checks, including exact trace/nonzero-counter
agreement, zero reference after stopping playback, continued capture after
stop, playback restart, disabled-mode passthrough, rejection after disposal,
idempotent disposal and creation of a fresh backend. Its retained trace is
222,720 bytes, containing 95,840 nonzero samples.

The complete digital evaluation also runs inside Chrome via
`tools/web/digital_test.html`; `results/web-browser-digital.json` passes every
target with the same numerical measurements as the Node/Wasm run. Build and
run these focused tests from the lab directory:

```sh
python3 tools/prepare_aec.py
python3 tools/build_wasm.py
node tools/web/test_aec.mjs
python3 -m http.server 8876 --bind 127.0.0.1
# In another terminal:
node tools/web/run_headless.mjs http://127.0.0.1:8876/tools/web/digital_test.html 45
node tools/web/run_headless.mjs http://127.0.0.1:8876/tools/web/aec_audio_test.html 30
```

The recorded toolchain is Emscripten 6.0.12-git, Node 26.12.0 and Chrome
155.0.8059.80 on macOS. C sources must compile as C: an initial all-`em++`
attempt mangled the QMF functions and failed to link. The builder compiles C
with `emcc`, C++ with `em++`, and caches objects in ignored `build/` using
source/header/toolchain hashes. Wasm uses the scalar code path with
`WEBRTC_POSIX`, relying on the vendor's `__EMSCRIPTEN__` architecture branch.

## Flutter acquisition and acoustic probe

`app/lib/web_acoustic_probe.dart` is a separate entry point with a Start button.
It uses one record stream (48 kHz mono PCM16, EC/NS/AGC disabled), one browser
camera stream through CaptureBridge, and the standalone AEC backend. The eight
phases and far/near waveforms match the Android acoustic probe: baseline,
digital near-only, far warmup, far-only, double talk with digital near injection,
quiet, far restart, and quiet after. The digital near-end is added only to
capture, never to playback. Playback/capture sample counts and maximum gaps
are reported; an observer records getUserMedia acquisition counts and selected
audio processing settings without device IDs or labels.

The probe reports pipeline continuity separately from acoustic quality. Only
an explicit `?labtest=true` exposes in-memory raw, mixed, near, clean, submitted
reference and actual-render PCM as `window.aecDiagnostics`. `run_probe.mjs`
can retrieve those buffers into an ignored local artifact directory when
`AEC_ARTIFACT_DIR` is explicitly set. No PCM is placed in the repository.

```sh
cd app
flutter build web --target lib/web_acoustic_probe.dart --output build/web-acoustic
python3 -m http.server 8878 --bind 127.0.0.1 --directory build/web-acoustic
# From the lab directory in another terminal: fake devices, muted output
AEC_ARTIFACT_DIR=build/web-acoustic-fake node tools/web/run_probe.mjs \
  'http://127.0.0.1:8878/?labtest=true&fake=true' 90
```

The runner invokes the same Start callback with a CDP user gesture. Fake runs
mute Chrome output so they do not contaminate simultaneous physical tests.
`AEC_REAL=1` instead selects visible Chrome with actual default input/output
devices and audible playback. Physical runs must be serialized with other
speaker tests. The local artifacts can be analyzed by
`tools/web/analyze_acoustics.py`; it uses the same correlation/projection method
as the native probe analyzer. Real microphone recordings remain local.

The Flutter fake run passes all eight acquisition phases
(`results/web-flutter-fake-acoustic-probe.json`), with one microphone and one
camera getUserMedia call. The real-device run also passes continuity
(`results/web-flutter-real-acoustic-probe.json`). Its track settings confirm
48 kHz, mono, 16-bit, EC/NS/AGC false. Using actual output-callback PCM as the
reference, `results/web-acoustic-analysis.json` measures correlated-echo
reduction of 15.34 dB in far-1, 23.59 dB after restarting far playback, and
6.40 dB during capture-only digital double talk. Digital near-end matched gain
is -0.216 dB alone and -0.209 dB during double talk; no microphone samples clip.
This is a real speaker/microphone echo-path observation, while near-end
preservation is tested with a digital injection, not a human speaker.

The foreground real run still has maximum callback gaps of 252 ms for audio
and 285 ms for camera, and 109,152 output underrun-zero samples (2.27 s,
including startup), without overflow or DSP errors. The main-thread prototype
therefore does not establish glitch-free production playback. Correlated
projection and RMS reduction also do not establish subjective speech quality.
Default input/output device routing was used; room/device distance and sound
pressure were not controlled. The physical measurements are one run, not
cross-device or cross-browser validation.

## WebRTC paths with the same capture

`app/lib/web_rtc_probe.dart` adds two local host-ICE peer connections. The
far-end fixture enters an external audio track, passes through WebRTC
encoding/decoding, and only its decoded PCM feeds `AEC.render`. Actual output
callbacks still supply the reverse reference. The microphone PCM enters AEC;
cleaned PCM reaches another external track only during two transmit intervals.
The sender detaches its track between intervals and reattaches that same track.
Neither connection uses `getUserMedia`; the original record/camera streams
remain alive throughout.

The clean-track receiver is a muted decoder tap used for verification. Its PCM
is never sent to the speaker or AEC renderer, preventing a microphone feedback
loop. Receiver taps can continue emitting concealment/silence PCM after RTP
stops, so the probe also measures inbound RTP byte deltas after a one-second
drain in each gated-off phase. It records decoded energy to distinguish live
fixture/clean audio from mere zero-valued callbacks.

Build with `--target lib/web_rtc_probe.dart --output build/web-rtc-probe`, serve
that directory and use the same runner. Fake-device runs remain muted; an
unmuted physical run requires an exclusive speaker slot. This is a separate
entry point from the direct-playback acoustic measurement above.

`results/web-flutter-rtc-fake-probe.json` passes the muted fake-device run:
one audio and one video acquisition, two clean transmit starts, nonzero decoded
energy on both paths, and zero clean inbound RTP-byte growth after drain in
every gated-off phase. Active-phase clean RTP-byte deltas are 21,995 / 19,252 /
24,380 / 22,678. This establishes the WebRTC transport wiring and gating;
fake input and muted output provide no acoustic evidence.

The unmuted real-device WebRTC run also passes
(`results/web-flutter-rtc-real-probe.json`). Clean input is injected during two
transmit intervals, and every off phase has zero inbound RTP-byte growth after
drain. Microphone/camera acquisition remains one call each, with browser
EC/NS/AGC false. The two clean WebRTC receive periods contain nonzero energy;
their tap remains muted and is never routed to the AEC player.

`results/web-rtc-acoustic-analysis.json` measures correlated-echo reduction
11.91 dB in far-1, 13.90 dB after the far restart, and 8.80 dB during digital
double talk. Digital near matched gain is -0.207 dB both alone and during
double talk, and clipping is zero. Maximum capture callback gaps are 49.6 ms
for audio and 78 ms for video. The output callback records 1,792 underrun
samples (37.3 ms) with no overflow. Its submitted-versus-consumed counters
show about 357–367 ms of player queue throughout the phases. This stable
buffer adds conversation latency and has not been optimized. These are single
physical observations; differing ambient conditions and scheduling prevent
ranking direct versus WebRTC playback by these runs.

## Saved results

| Evidence | Result |
| --- | --- |
| [Wasm digital](../results/web-digital.json), [Chrome digital](../results/web-browser-digital.json) | Same deterministic measurements; all regression targets pass |
| [Worklet lifecycle and trace](../results/web-worklet-smoke.json) | 13 checks pass; exact consumed PCM/zero trace retained |
| [Flutter fake acquisition](../results/web-flutter-fake-acoustic-probe.json) | Eight phases pass, one audio/video acquisition |
| [Flutter real acquisition](../results/web-flutter-real-acoustic-probe.json), [direct acoustic analysis](../results/web-acoustic-analysis.json) | Physical echo reduction and digital near retention measured |
| [Flutter fake WebRTC](../results/web-flutter-rtc-fake-probe.json) | Two transmit starts, gated RTP stops, live decoded far/clean audio |
| [Flutter real WebRTC](../results/web-flutter-rtc-real-probe.json), [WebRTC acoustic analysis](../results/web-rtc-acoustic-analysis.json) | Actual decoded-far playback and cleaned-mic transmission verified |
| [Coarse-alignment failed evaluation](../results/web-digital-coarse-alignment.json) | Preserved failure; one-sample lag search fixes the evaluator |

All PCM stays in ignored local `build/` directories. Committed acoustic results
contain metrics and artifact hashes, without recordings, device IDs or labels.
