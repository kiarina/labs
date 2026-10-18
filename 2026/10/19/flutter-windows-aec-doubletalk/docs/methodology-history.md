# Historical experiment notes

This is the retained sequence of exploratory decisions and rejected methods.
The root README describes the current implementation and interpretation.

# Windows continuous capture double-talk AEC

## Question and evaluation fixed before new physical trials

Keep camera + record acquisition alive, and improve echo rejection while a
near signal is present. WebRTC must never open an extra microphone. This lab
adapts the [five-platform AEC experiment](../flutter-external-capture-aec/README.md)
independently; old results and SDK caches remain unchanged. Transport and DSP
versions stay pinned to isolate the improvement from dependency changes.

First audit old microphone/reference recordings, device routing and stimulus
bandwidth. A weak scalar chirp correlation is not a robust echo-energy metric.
Do not count a new stimulus or a corrected estimator alone as DSP improvement.

Primary comparison uses one captured raw microphone input and its actual
speaker reference, with a known independent near signal added only to capture.
Replay identical captured data through baseline and candidate DSP schedules/
settings. Use band-limited seeded broadband excitation, aligned spectral echo
projection and held-out blocks, and measure near transfer separately. Physical
confirmation compares the selected candidate against the baseline in repeated
runs with the same stimulus, endpoints and levels; preserve failed trials.

Acceptance: measurable far path (raw/reference coherence over excited bands),
at least 25% of excited non-near frequency bins with raw coherence >=0.2 (and at least eight bins), DT echo reduction >=6 dB, near-only gain within +/-3 dB and DT near gain >=-6 dB,
no clipping as the source of attenuation, acquisition retained and all seven
WebRTC recording-init/start counters zero. Compare baseline and candidate DT
on identical input; require >=3 dB improvement to claim a DSP improvement.
If baseline already passes or near preservation worsens, report that explicitly.
Real human speech, background capture, Bluetooth and all hardware remain outside
this short fixture test. A missing Windows camera must be labelled synthetic,
while the camera-capable capture path is retained.

## Status

Auditing old data and preparing offline comparisons. No new physical result yet.
Only derived metrics enter Git; microphone PCM remains ignored in build/.

## Comparison implementation

The owned output feeds identical render PCM to baseline internal AEC delay
estimation and three independent external-delay variants (80/120/160 ms).
One `record` chunk feeds all four engines in the same native call. The 120 ms
variant is sent downstream for transport checking; this does not select it as
the quality winner. Candidate selection uses warmup/far-only data, then the
double-talk interval is held out for acceptance. Near gain is measured from
the known capture-only near fixture. Aperiodic far excitation uses xorshift32
seed123456789 through a two-lowpass difference (.63/.965), bounded peak9000.
The old invalid chirp is not used in this comparison. Fixed source versions:
Flutter3.47.2/Dart3.13.2, record7.1.2/record_windows2.3.0, camera0.12.1/
camera_desktop2.0.0, flutter_webrtc1.6.2+hotfix.4; AEC extraction pin
`2cec2f52e26646f93bd2d5498bbabf59cba18da9` (BSD-3-Clause). The extraction's
upstream WebRTC revision is unspecified. The audited transport SDK remains the
same m150-derived lab binary; its recording audit must stay zero.

`tools/analyze_trial.py` uses 1-second raw windows, a shared raw-only +/-10ms
lag refinement and Welch cross-spectra (1024 points / 50% overlap). It excludes
+/-70Hz around the known near harmonics. At least 25% of excited bins (and eight
bins/window) must reach raw/reference coherence0.2. The candidate is selected
on far-1 after filtering by near-only retention; DT is held out. The same raw
mask and alignment are used for every candidate. Frame-clock normalization in
AEC's external estimator is part of the pinned implementation; delay hints
must not be interpreted as independently measured hardware ADC latency.

## Trial 1 and next controlled condition

The aperiodic-noise trial's far-only capture is identifiable and baseline already
rejects it strongly. During DT the **pre-AEC raw** mic decays to exact zero for
four seconds while the render reference continues. That DT interval fails the
identifiability criterion and is not accepted as a suppression result. Endpoint
mute was false; current level was unchanged. Stationary-noise suppression in the
capture device/APO is a hypothesis, not established causality.

The next condition uses the existing public shared Japanese speech fixture
instead of stationary noise. Run `mise run //:test-assets:download` then
`python3 tools/prepare_speech.py`; the source and normalized PCM hashes are
recorded in results/speech-fixture.json. Set EXTERNAL_FIXTURE=speech. This changes
the excitation only; baseline and every candidate still process identical input.
Add an external100ms alignment and external80/100ms with doubled filter tail
(26x4ms versus13x4ms) to investigate reverberation without aggressive near muting.
Candidate selection and DT acceptance thresholds remain unchanged.

## Independent analysis review (before interpreting speech candidate results)

The first estimator used per-window average coverage and selected bins on the
same data being scored. Review identified possible upward bias and near
sidelobe leakage. Version2 fixes the frequency mask on **warmup raw/reference**
plus the known near-only fixture PSD; far-1 selects a candidate and DT remains
held out. Each active 1-second DT window must independently satisfy raw level
>-85dBFS, zero fraction<.95, coherence coverage>=25% and >=8 bins; at least75%
of active windows and three windows must pass. Near delay is calibrated on
baseline near-only and fixed for all outputs. Positive signed gain and near-only
correlation>=.95 are required. DT near gain may degrade at most0.5dB relative to
baseline, and echo improvement is normalized for that near attenuation. A
near-only negative control bounds the residual measurement floor. These
post-collection review changes require a fresh repeated speech trial with the
frozen analysis before a processing-improvement claim. V1 exploratory outputs
remain retained rather than silently replaced.

Before fresh trial3, version3 makes the primary estimand the ratio of summed
coherent powers over valid1-second windows. The bootstrap resamples those same
paired powers, so its interval now estimates the reported improvement rather
than a different mean of per-window dB values. Overall acceptance also requires
one microphone start and successful transport gates. Trial2 v1/v2 remain
exploratory. Trial3 predeclares **strict80**, external80ms with normal residual
masking thresholds during near-end dominance; it is not selected on trial3 DT.
A same-input known-speech near retention check is required before physical use.

Version4 (frozen before trial3) averages complex cross-spectra across valid
windows **before** squaring magnitude, as Welch coherence requires. Summing
per-window squared magnitudes (v3) adds incoherent near-distortion/noise bias.
The paired block bootstrap recomputes that same complex-average statistic.
The frequency mask still comes only from warmup and known-near PSD, and each
raw window must pass the fixed identifiability gate. Trial2 v3 is retained.
Strict80 was rejected offline: it worsened near-speech retention. The fresh
candidate is now **gentleRefined80**, external80ms, coarse filter output disabled
and near-dominant mask ENR thresholds multiplied by5. Same-input known-speech
near checks passed (DT correlation.9731 versus baseline.9085, gain-.82 versus
-2.24dB); the next physical trial tests echo rejection independently. It changes
DSP only, not capture ownership, endpoint configuration or OS effects.

## Trial 4 and aligned linear output

Trial 3 gentleRefined80 failed the frozen v4 acoustic criterion: normalized
improvement -1.48 dB (95% interval -2.35 to1.55). Profile12 linear80 was first
measured with an inconsistent output delay; the retained initial-alignment JSON
is diagnostic only. Its exported low band precedes the ordinary high bands by
64 samples at16k. Delaying that band aligns all variants at431 samples48k in the
independent speech replay. A fresh MF physical trial4 still failed acoustic
improvement (-2.35dB, interval -3.01 to2.15), despite better near retention.
The next test changes only the record backend to explicit per-stream RAW.

## RAW ownership, delay and filter-tail exploration

Trial5 requested RAW successfully, used one input and no MF capture, and stopped
with active0/HRESULT0. This is capture ownership evidence, not proof of bypassing
microphone firmware. DT identifiability failed (57% valid windows) and linear80
underperformed baseline. Same-input re-clocked replay explored linear delay
20–200ms, 26-block linear filters, and 26-block refined residual suppression.
Far1 selection retained baseline. An exploratory DT value for longRefined120 was
10.2dB versus baseline7.94, which is insufficient to claim improvement. Independent
near-speech replay gave corr.9761/gain-.506dB/minimum100ms gain-2.93dB, so trial6
predeclared that candidate for a fresh test. To improve weak raw/reference
identifiability, trial6 doubles only the application speech fixture (peak18000);
all engines still see exactly the same capture and render. OS levels stay fixed.
No later candidate search is planned for this lab.

Analysis dependencies used here are NumPy2.5.4 and SciPy1.18.1; see
`../requirements-analysis.txt`. Offline replay changes callback timing, so it
cannot substitute for fresh physical confirmation. `replay_raw_delays.py --mode`
accepts `delay`, `long`, or `refined` and saves ignored PCM into distinct folders.
