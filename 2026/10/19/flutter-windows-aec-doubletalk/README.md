# Windows continuous capture double-talk AEC

Keep `camera` + `record.startStream` acquisition alive and send processed audio to
WebRTC only when needed. AEC owns no capture device. The Windows transport SDK
must report zero additional recording operations. This independent lab adapts the
[five-platform experiment](../flutter-external-capture-aec/README.md).

## Physical human speech

The [human double-talk protocol](HUMAN.md) extends this lab with real participant
speech, on-screen cues and decoded WebRTC receiver recordings. One short physical
near-voice trial passed the predeclared checks and participant listening: far-only
reduction20.6–23.1dB, clarity4–5/5, no missing words, echo none-to-slight, normal
near recovery. This is limited to the measured setup, baseline AEC and recorded
far fixture; live DT source separation and long-session practicality are not proved. It uses
`app/lib/human_probe.dart`; synthetic-near results below remain a separate test.

## Result and adoption

**No candidate established better acoustic double-talk suppression than baseline.**
The final RAW trial met the absolute quality criterion (10.41dB render-coherent
reduction, near gain -.21dB), but the same-input baseline achieved12.10dB.
The normalized difference was -1.70dB, paired95% interval[-3.71,2.78]. Do not
adopt the candidate as an echo improvement. The lab application defaults to baseline;
reproduction of trial6 explicitly selects `longRefined120`.

| Trial | Capture / candidate | DT baseline → candidate dB | Raw interval identifiable | Improvement claim |
|---|---|---:|---|---|
| 1 | MF / noise excitation | not valid: raw mic became zero | no | no |
| 2 | MF / external80 | 3.32 → 3.82 | yes | no |
| 3 | MF / gentleRefined80 | 2.44 → .96 | yes | no |
| 4 | MF / linear80 | 2.13 → -.22 | yes | no |
| 5 | RAW / linear80 | 7.23 → 4.08 | no:57% valid windows | no |
| 6 | RAW / longRefined120, speech gain2 | 12.10 → 10.41 | yes:86% valid windows | no |

Trial6's `longRefined120` uses external delay estimation with a120ms hint,
26-block filters and disables coarse filter output, retaining normal residual
suppression. Same-input offline replay with independent capture-only speech
improved near correlation .9260 → .9761, gain -1.66 → -.51dB and minimum active
100ms gain -9.95 → -2.93dB, with no active-window run below-6dB. This establishes
near preservation in that fixture, not improved physical echo rejection.

The opt-in lab-local `record_windows` fork successfully captured through one
explicit RAW WASAPI input: RAW request/accepted/start1, MF captures0, runtime
HRESULT0 and active inputs0 after disposal. All seven WebRTC recording counters
remained0 and both transport gates plus received-far playback passed. Maximum
record callback gap was16.68ms in trial6. This is single-input ownership evidence;
RAW acceptance does not prove microphone firmware is bypassed.

Only derived metrics enter Git. All six physical trials and rejected configurations
remain retained; microphone PCM stays local and ignored. Trial6 changes application
speech gain to2 (actual reference peak18000), so differences between trials5/6
cannot be attributed to DSP or RAW alone. Baseline/candidate comparison *within*
each trial uses identical samples. The collected trial6 report's fixed
`farPcmPeakBound=9000` metadata is stale; `farSpeechGain=2` and measured peak18000
are authoritative. The source now calculates that bound correctly.

## Data path

`camera` / `record` → shared raw capture → baseline and candidate AEC engines →
selected clean output → optional WebRTC track. Received WebRTC far audio goes to
the owned WASAPI speaker, whose actual submitted PCM (including silence) feeds
all reverse AEC streams. WebRTC native playout and its null poller are disabled
in the audited SDK so that the owned speaker is the sole decoder clock.

One explicitly selected controller microphone and a stereo 96 kHz speaker are
used. Global device settings and effect properties are unchanged. The default
`record_windows` Media Foundation capture does not guarantee bypassing OS effects,
even with its three processing flags false. The optional
[RAW stream fork](patches/record_windows/README.md) requests unprocessed capture
per stream, retains the Dart record API, and fails explicitly without MF fallback;
its single-input ownership and shutdown were validated in trial5, while the
AEC improvement criterion still failed. No physical Windows camera is available in
these runs, so video is explicitly synthetic; the real camera path remains.

## Measurement and acceptance

The far fixture is shared Japanese speech, normalized to base peak9000 (trial6 applies gain2, peak18000). The physical
speaker/mic path is real; known independent near harmonics are added only to
capture. Every DSP variant processes the same raw and actual render samples.
The candidate is fixed before its fresh trial; double-talk is held out.

`tools/analyze_trial.py` version 4 fixes a 300–3500 Hz frequency mask on warmup
raw/reference coherence and excludes the known near PSD. Each one-second raw
window requires at least eight coherent bins and 25% coverage. At least three
windows and 75% of active windows must pass. Complex cross-spectra are averaged
before squaring; the paired bootstrap recomputes that same statistic. This measures
render-coherent component reduction, not total broadband echo energy. A near-only
negative control diagnoses the floor but cannot bound distortion induced by DT.

Acceptance requires DT reduction ≥6 dB, near-only positive gain/correlation ≥.95
and gain within ±3 dB, DT near gain ≥-6 dB and no more than .5 dB below baseline,
no clipping, one microphone start, successful transport gates, and all seven SDK
recording counters zero. An improvement claim additionally needs ≥3 dB reduction
normalized for near attenuation and a paired 95% interval above zero. The baseline
must not be floor-limited. Offline independent speech retention additionally needs
DT correlation ≥.95 and no loss of short-window near gain relative to baseline.

## Reproduce

See the complete [Windows build and run steps](docs/windows-run.md). `mise run`
checks retained evidence and claim guards without opening devices.
`mise run digital` rebuilds and runs the deterministic DSP fixture.

Use Flutter 3.47.2 / Dart 3.13.2. Run the repository shared
`mise run //:test-assets:download`, then `python3 tools/prepare.py`,
`python3 tools/prepare_speech.py`, and `python3 tools/prepare_record.py`.
Build the standalone native AEC library with CMake before the Flutter Windows app.
The manual-playout/recording-audited transport SDK from the preceding lab is
required. Never substitute a normal SDK and treat absent audit exports as zeros.

Set `EXTERNAL_FIXTURE=speech`, `EXTERNAL_CAMERA_MODE=synthetic`,
`EXTERNAL_OUTPUT=longRefined120`, `EXTERNAL_EXIT=true`, and
`EXTERNAL_CAPTURE_RECORDING_CONTROL=0`, `EXTERNAL_FAR_GAIN=2` for final trial6. Set `AEC_RECORD_RAW=1` only for the explicit
RAW experiment; otherwise use 0. Keep the same endpoints/levels for comparisons.
Microphone PCM stays ignored under `build/`; only derived metrics enter Git.
Analyze with `uv run --with-requirements requirements-analysis.txt python
tools/analyze_trial.py ARTIFACTS OUTPUT --candidate longRefined120`.

Pins: record 7.1.2 / record_windows 2.3.0, camera 0.12.1 / camera_desktop 2.0.0,
flutter_webrtc 1.6.2+hotfix.4. Versions are intentionally held constant with the
preceding experiment to isolate DSP/capture changes. Standalone AEC extraction:
`2cec2f52e26646f93bd2d5498bbabf59cba18da9` (BSD-3-Clause); its upstream WebRTC
revision is unspecified and is not claimed identical to the transport SDK.

See [legacy diagnosis](docs/legacy.md), [methodology history](docs/methodology-history.md),
[speech fixture hashes](results/speech-fixture.json),
[known-speech near replay](results/offline-speech-near.json), and
[digital linear fixture](results/digital-linear.json). Real human near speech,
Bluetooth, long drift and other Windows hardware remain unverified.

## Diagnostic limitations

The separate linear80 diagnostic replaces the exported linear low band and delays
it64samples16k before synthesis. Impulse and7–9k/15–17k sweeps found no extra band
misalignment versus baseline. However it bypasses normal unconverged-filter output
selection, and fullband near/noise stress showed14–21dB near suppression in higher
bands that still use normal NLP. It is not a fullband near-preservation solution.
See [band/start/path-change diagnostics](results/linear-band-check.json).

The original chirp had an incorrect phase expression and excessive aliased energy;
its old scalar1.29dB value is not comparable with this lab's coherent spectral
metric. Neither a better stimulus nor a corrected estimator alone is an AEC gain.
The MF/RAW microphone path can still be nonlinear or time-varying; the exact cause
of trial1 silence is unproven. Real human near speech, other capture hardware,
Bluetooth, high-band DT fidelity and long drift remain unverified. No product or
five-platform adoption policy is changed by this Windows-only experiment.

See [Windows SDK requirements and alternatives](docs/windows-sdk-alternatives.md)
for the distinction between the measured custom SDK and proposed stock-runtime paths.
