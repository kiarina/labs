# Mac double-talk dropout investigation

Status: investigation started; no improvement accepted yet. Uses the existing
external-media fork4477798 and bridge9f5e2da (0.1.0-dev.2) with continuous real camera/record.
This independent fixture owns copies of the predecessor source and private
baseline artifacts; no runtime imports from another lab. Only macOS is targeted.

## Questions and criteria fixed before new measurements

Separate (1) raw-input/AEC near-speech attenuation from desired far-echo removal,
(2) native-source starvation/flush gaps, and (3) RTP/decoder loss. Raw-to-AEC RMS
alone does not identify near gain during double-talk. The previous human trace
has no native queue drops and no phase-interior render-reference drops. All
68native underflows must be localized rather than dismissed using aggregate counts.

First compare saved same-event input/reference through bounded fixed gain
conditioning with unchanged baseline AEC; check nominal PCM headroom and far-only
cancellation against baseline. Then use a known digital near-speech reference
with real record capture and physical far-speaker playback to measure100ms near
projection windows. Preserve one microphone owner and actual camera frames;
no raw bypass, added microphone, second speaker or hidden SDK AEC is allowed.

Candidate: no input/output overrange, DSP errors or unaccounted capture loss;
far-only identifiable reduction>=15dB and at most1dB worse than paired baseline;
known-near100ms gains>=-6dB with no repeated missing windows; near-only gain within
+-3dB, correlation>=.95. Native starvation during audible clip interiors is a
separate failure. Weak acoustic coherence is inconclusive. Human reception then
requires participant confirmation of improved missing words, no pumping and echo
none/slight, using separate continuous clips with common gain<=1. Preserve
camera/record once, capture/DSP during gates and zero SDK input with a positive
observer sensitivity control. Do not claim synthetic or offline improvements are
live human success. Reconnection/long sessions/other devices/OS remain outside.

## Starting evidence

[Predecessor](../flutter-fork-external-media-aec/README.md) reports Mac echo none,
generally good but slight double-talk loss. Saved baseline is byte-replayable.
Record emits approximately100ms chunks; native FIFO200ms has overflow/inactive
loss0. The application currently flushes on repeated send-on phase transitions;
its effect must be distinguished from interior speech loss. Baseline profile is
unchanged until a candidate passes the new comparison and listening.

Pins/toolchain remain as in app/pubspec.yaml/lock: Flutter3.47.2/Dart3.13.2,
record7.1.2, camera0.12.1/camera_desktop2.0.0, standalone AEC3 extraction2cec2f52.
No dependency upgrades or paid API calls. Third-party provenance is in
THIRD_PARTY.md. Raw voice, images and detailed device traces stay ignored/private.

## Reproduce on Apple Silicon macOS

Use a locally installed Flutter3.47.2 and Python3.12 with the pinned lockfile.
The Apple DSP preparation is ARM-only; universal profile/release builds are not
supported by this fixture (x86 compilation fails at ARM NEON sources). Use debug
on Apple Silicon; this is a lab build limitation, not a runtime AEC result.

```sh
python3 tools/prepare_aec.py
mise run //:test-assets:download
python3 tools/prepare_speech.py
python3 -m venv build/venv
build/venv/bin/pip install -r requirements-peer.txt -r requirements-analysis.txt
cd app
flutter pub get
flutter analyze lib
flutter build macos --debug
cd ..
build/venv/bin/python tools/peer.py --speech app/assets/far_speech.pcm --output build/peer --port 18798
```

In another terminal, build the independent observer as in tools/macos/README.md
and launch with AEC_PEER=http://127.0.0.1:18798, AEC_SESSION unique per trial,
AEC_HUMAN=1, AEC_AUTO_START=0, AEC_EXIT=1 and the observer preload. Select built-in
input and system built-in speaker before starting. Human mic-check and manual
quiet calibration prevent a silent/incorrect device from becoming a pass.
Use AEC_HUMAN=0/AEC_AUTO_START=1/AEC_NEAR_GAIN=0.5 for known-near injection with
physical far echo. This is a signal probe, not a substitute for human speech.
Run the negotiated AEC_SDK_MIC_CONTROL=1 sensitivity control separately.

The report pointer mac_dropout_latest.json is in the app sandbox temporary
directory. Copy that trial folder into build/TRIAL/artifacts. Use analyze.py,
near_windows.py (name inherited; signal analysis is platform independent),
summarize_capture.py and analyze_continuity.py to produce aggregate JSON.
listening.py --max-gain 1 produces private receiver clips without amplification.
The peer runs on loopback without STUN/TURN or paid APIs. Raw microphone audio,
camera pixels, receiver PCM and device call stacks must remain ignored/private.

## Measurements in progress

The dev.2 bridge coalesces repeated same-target send requests, preserving pending
PCM/video and avoiding native flush on true-to-true. Three regression tests fail
before this change; all13 tests and analyzer pass afterward. The fixture also
avoids its own repeated-state generation reset. Actual stop/resume still flushes
stale queued input. This repairs a continuity defect; it does not prove the sole
cause of the previously reported small interior loss.

Saved original baseline replays byte-identically. Bounded gain2/gain4 conditioning
has not established better words; it is offline-only and is not selected live.
On renewed listening the participant found no large loss in either saved DSP
output or received audio. New live known-near results still have short attenuation
windows; do not claim all predeclared acceptance criteria passed.

First automatic launch stopped at record start with audio format error-10868,
zero capture, while OS defaults were Bluetooth. Retest after selecting built-in
input/output succeeds. That observation is not proof of the exact error cause or
Bluetooth support. New test uses built-in speaker at50% system volume.

Automatic corrected-gate run: capture/processing/send-off/resume passed with one
camera/record start and independent SDK input0. Negotiated SDK positive control
shows one SDK input engine/audio unit enable/start. Far-only coherent reductions
46.15/44.78dB are identifiable (not broadband ERLE). No native queue drop; all
submitted PCM is accounted for. Phase-end render-reference drops0; teardown
adds70ms separately. One10ms underflow remains6.8s into doubletalk-1 at a128.52ms
callback interval. Deliberate muted intervals include zero-fill and are excluded
from speech-interior interpretation. Known-near100ms windows still include
500/700ms runs below-6dB, so this is not an all-criteria pass. Overall near-only
correlation.845 also misses the predeclared.95 threshold. Baseline live AEC is
unchanged; the physical human test remains necessary.
