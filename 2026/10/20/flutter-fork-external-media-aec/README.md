# Physical capture, AEC and sender gates through the fork and bridge

One physical camera stream and one `record` PCM stream remain running through
sender off/on on macOS and Windows. The pinned public fork API and connection
library deliver processed PCM/video to an independent receiver without another
SDK microphone acquisition. **This is not loss-free/all-criteria acceptance:**
the participant reports slight missing speech during Mac double-talk; Windows
receives a positive general listening assessment but still has full-scale peaks.

## Results and scope

| Fixture | Capture / SDK additional mic | Sender off / resume | AEC and human assessment |
|---|---|---|---|
| Apple Silicon notebook, FaceTime HD + built-in mic/speaker | one record input engine, one camera start, SDK input0; positive default-SDK control detects input | source camera2613frames and continuous PCM/DSP; gate-off2s adds192000raw/processed bytes and60camera frames, receiver adds0audio/video; reception resumes | far-only identifiable reduction47.10/47.55dB; participant: generally good, no echo, slight loss during DT |
| Windows x64, Pixel Fold via OS virtual-camera transport, DualSense, external USB speaker | record RAW1, SDK mic0, speaker1, render-loopback1; ETW lost0, same-endpoint SDK positive control1 | physical source2809frames; gate-off2s adds192000raw/processed bytes and61camera frames, receiver adds0audio/video; reception resumes | far-only35.24/29.65dB; participant: “良いと思う”; DT echo not independently identifiable |

These are real sensor images (Windows1280x720 provider), resized only on the
send/processing branch to160wide at at most8fps. Native camera callbacks continue;
no generated-video fallback is present. Windows phone transport is an OS virtual
camera backed by the connected/approved phone, not a directly attached USB webcam.
Camera pixels, raw/processed/decoded audio and raw traces are private/ignored.

[Mac capture](results/mac-human-1-capture.json),
[Mac input observer](results/mac-human-1-inputs.json),
[Mac assessment](results/mac-human-1-assessment.json),
[Windows capture](results/win-human-1-capture.json),
[Windows ownership](results/win-human-1-ownership.json),
[Windows assessment](results/win-human-1-assessment.json).

The Mac reference lost one10ms block during shutdown; every recorded phase ends
with reference-drop0. It cannot explain an earlier DT interior by itself. Native
capture overflow/inactive drops are0 after the queue fix. Explicitly flushed
old samples are separately counted. Mac record callbacks are approximately100ms
bursts (maximum115.18ms); Windows RAW maximum14.04ms. Acquisition staying open is
not a claim of low callback latency or rigorous long-duration sample-clock sync.

[Acoustic metrics](results/mac-human-1.json),
[Windows metrics](results/win-human-1.json),
[delivery diagnostics](results/mac-human-1-dropouts.json).
Coherent reduction is not broadband ERLE or independent clean-near gain. Windows
human DT lacks adequate raw/reference coherence, so its echo separation is
inconclusive even where partial reductions are calculable. Positive listening is
not rewritten as a numeric clarity rating or explicit per-item “no loss” answers.

Windows baseline DSP/decoded output still contains584/667 exactly full-scale
samples. Near-full-scale raw samples are not proof of ADC clipping.
[Peak counts](results/win-human-1-peaks.json). The existing baseline remains in use;
no headroom/conditioning profile is adopted by this verification.

## Dependency and ownership contract

[Pins and source identity](results/pins.json): Flutter fork4477798,
bridge8c8ebe2 (`0.1.0-dev.1` Git package), Windows SDK20261020.1/DLL73b672….
Windows installer verifies its archive plus51extracted files. Mac human1 used
bridge6f11ddd with the explicitly pinned Git fork4477798 override. Final bridge8c
changes dependency pin/docs only: all bridge Dart files are byte-identical;
10tests pass with the final direct pair. Windows human1 uses the direct final pair.
Flutter20tests and lab Dart analysis pass.

Capture packages intentionally match the proven predecessor fixture: record7.1.2,
lab RAW record_windows2.3.0, camera0.12.1/camera_desktop2.0.0. The lockfile records
actual transitive versions. These pins isolate the transport/queue comparison;
they are not a general dependency-upgrade recommendation. Flutter3.47.2/Dart3.13.2.
See [third-party provenance](THIRD_PARTY.md).

The application owns camera/record, preprocessing, permissions and peers.
`flutter_webrtc_external_media` owns bounded packetization, source-wide sending
gates, flush and disposal; it does not own physical capture, AEC or authentication.
This lab copies/owns its standalone AEC3 and platform adapters. Consumers must
adapt these into their own owned processing module; they must not import a lab
path. Mac AEC reference comes from the fork output-only custom ADM device using
AVAudioEngine/system-default output. Windows keeps normal native SDK playout;
selected-endpoint WASAPI render loopback supplies reference without another mic
or speaker. Select the Windows speaker after peer creation, before negotiation.

One source per factory and one shared gate are supported. This is not a per-peer
privacy switch. Queued/partial stale media is discarded on stop; already-submitted
RTP/decoder buffers cannot be retracted. Sender-off did not interrupt capture/DSP.
New-peer reconnection, long sessions, hardware/permission changes, Bluetooth,
background operation and Android/iOS/Web remain untested or unsupported here.

## Criteria fixed before measurement

Require real frames, increasing record/camera/DSP counters during sender-off,
RTP reception after resume, SDK additional mic0 with independent positive-control
sensitivity and clean shutdown. Distinguish render-loopback from physical input.
Require ETW lost events/buffers0 on Windows. Observe the process under test, not
all other applications on the computer.

AEC: identifiable far-only reduction>=15dB; known-near DT projection>=-6dB and
echo reduction>=6dB. Weak raw/reference coherence is inconclusive. Human additionally
requires clarity>=4/5, no repeated missing words/pumping and echo none/slight.
Separate continuous clips use common gain<=1; do not judge a combined edit as a
live missing syllable. Neither platform is declared to pass every criterion:
Mac has reported word loss; Windows lacks complete per-item ratings and has
full-scale output. Synthetic known-near tests do not establish preserved physical
human speech when microphone energy dominates the injection.

## Failures and changes

- Initial four-DSP/320px Mac fixture caused reference drops256320bytes and invalid
  acoustic calibration. One live baseline processor plus160px/8fps conversion
  removes phase-interior reference loss; native camera input remains continuous.
- About100ms record bursts plus scheduling jitter reached110–120ms queued. The
  original100ms native FIFO overflowed. The fork now allows200ms and exposes
  inactive/overflow/flush counts separately. Queue200smoke submitted800blocks,
  peak110ms, drops0. Human capture overflow/inactive drops0. A larger bound is not
  a latency promise or a cure for the remaining Mac AEC loss.
- Windows medium camera preset failed twice, including after phone unlock and
  approval. Pixel Fold only offered1280x720 in this fixture. Windows max preset
  succeeds without a capture-package patch; failures remain recorded.
- Mac observer initially recursed through dlsym(RTLD_NEXT), then one launch used
  a missing dylib. Both failed runs are excluded. Corrected debug instrumentation
  calls original symbols from its own image and observes input-node/input-enable/
  unit-start stacks. Default SDK control detects an SDK input engine/unit;
  external-only human run detects record1 and SDK0.
- gUM without negotiation did not start real recording and is an invalid
  sensitivity control. Negotiated Windows positive2 detects SDK mic1 with lost0;
  its endpoint matches the record input. [Windows control](results/win-positive-2-sensitivity.json),
  [Mac control](results/mac-positive-control-3-inputs.json).
- Shared Windows pub cache initially yielded a missing-transitive-dependency
  package graph. An isolated PUB_CACHE resolved it; shared cache was preserved.

Mac human baseline replays byte-for-byte using the recorded reverse/capture event
order. Offline gain2/8 explorations retain far-only cancellation but have not been
sent/listened live; gain8 exceeds nominal input headroom4795samples and is not a
live candidate. Gain2's preserved echo is not proof it fixes missing syllables.
[Replay identity](results/mac-human-1-replay-verification.json),
[gain2 analysis](results/mac-human-1-replay-gain2.json). No new DSP profile is adopted.

## Reproduction

From repository root run `mise run //:test-assets:download`. In this lab run
`python3 tools/prepare_record.py`, `python3 tools/prepare_aec.py` and
`python3 tools/prepare_speech.py`. Create a Python3.12 environment with
requirements-peer.txt/requirements-analysis.txt; `cd app && flutter pub get` and
build macOS debug or Windows release. Scripts prepare only this lab's vendor/
source; they do not patch the shared package cache or another lab.

Start `tools/peer.py --speech app/assets/far_speech.pcm --output build/peer --port
<port>` with localhost/private forwarding. Far speech plays only when requested;
the independent receiver never plays captured near audio. On Windows use an
elevated interactive desktop and tools/windows/build_observer.cmd with vcvars64,
then run_trial.ps1 with fresh output paths, a JSON manifest containing the
`dllSha256` from results/pins.json, microphone ID (or
human picker), CameraMatch/SpeakerMatch and peer URL. Collector refuses existing
WPR sessions, observes the actually loaded DLL hash and stops only its own trace.

Set AEC_HUMAN=1/AEC_AUTO_START=0 for human runs. Select the intended mic, press Start
and speak only when mic-check appears. Stop speaking before the quiet confirmation,
remain still8seconds, then follow near/far/DT cues. Capture remains active during
that dialog. A failed calibration aborts. Baseline is the only live profile.
The debug Mac observer is described in tools/macos/README.md. Do not weaken
production signing/security to enable it.

After each run collect the private report/PCM and analyze with tools/analyze.py,
ownership.py (Windows), macos/summarize_input.py, summarize_capture.py and
listening.py --max-gain 1. Native source/event replay can be built with
`cmake -S native -B build/aec-replay -DAEC_BUILD_PROBE=ON`, then
`cmake --build build/aec-replay`; tools/replay_conditioning.py reproduces exploration.
Raw private diagnostics and participant recordings must not be committed.
[Cleanup](results/cleanup.json): test apps, peer servers, forwards, temporary task
and WPR are stopped/removed. No paid API was called.

Predecessors: [native Windows playout](../../19/flutter-windows-native-playout-aec/README.md),
[external capture](../../19/flutter-webrtc-external-capture/README.md),
[earlier AEC](../../19/flutter-external-capture-aec/README.md).
