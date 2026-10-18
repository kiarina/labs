# Legacy recording diagnostics

Run without playing audio or changing the captured data:

```sh
uv run --with numpy --with scipy python tools/analyze_legacy.py \
  build/legacy results/legacy-diagnostics.json
```

The script reads only local PCM. Its output contains hashes, frequency-band
coherence, one-second lag peaks, near transfer, and stimulus spectral checks.
Raw microphone audio remains ignored under `build/`.

## Stimulus defect confirmed in the PCM

The old fixture evaluated `sin(2*pi*f(t)*t)` with
`f(t)=330+2200*frac(.71*t)`. This is not an integrated chirp phase. Away from
frequency resets its instantaneous frequency is
`330+3124*t-2200*floor(.71*t)`, with a phase discontinuity of `-2200*t` cycles at
each reset. Discrete sampling folds frequencies above 24 kHz back into the
48 kHz sampled signal.

Actual queued-reference STFT confirms this: 3,839 excited frames have a median
11.71 Hz peak error against the folded derivative prediction, with 100% within
150 Hz after excluding the fixed 701 Hz component, reset edges and spectral
boundaries. At 10 seconds nominal `f(t)` is 550 Hz but the observed peak is
16,171.9 Hz. At 16 seconds nominal frequency is 1,122 Hz but the observed alias
is 21,890.6 Hz. At 22 seconds it is 11,953.1 Hz rather than nominal 1,694 Hz.
72.64% of queued-reference spectral energy lies above 2.5 kHz. Consequently the
old test did not maintain the intended low-frequency excitation or a stationary
speaker/microphone transfer measurement.

## Acoustic observations and their limits

Near-only and double-talk digital near gain remain approximately -0.21 dB,
using the near-only alignment for both. This rules out complete silencing as
an explanation of the old cleaned output, within this controlled near fixture.
It does not establish preservation of human speech.

Raw/render coherence is frequency dependent. In the 680–725 Hz band containing
the fixed tone, median coherence is .301 for far-1, .183 for double-talk, .275
for far-2, and .368 for received far. In 2.5–8 kHz it is .048/.004/.284/.283.
Many other bands are weak. Low-frequency raw energy is substantial outside the
intended reference component; for example 80–330 Hz contributes 24.6% of far-1
and 39.8% of received-far raw power. These observations support improving the
excitation and spectral evaluation before interpreting scalar correlation.
They do not distinguish ambient sound, device processing and nonlinear echo.

One-second lag peaks vary substantially, particularly during early far phases.
Later blocks often find the same roughly 6,213-sample lag, but the periodic tone,
changing high-frequency alias and low SNR permit competing peaks. These peak
positions alone cannot establish sample-clock drift or a physical latency.

The old 1.29 dB double-talk scalar projection result describes one projection
of the waveform. It is neither the attenuation of all echo energy nor an ERLE
measurement. This diagnostic makes no DSP-improvement claim. A new experiment
needs known band-limited aperiodic excitation, identical-input DSP replay,
held-out transfer estimation, actual render/capture timing, and explicit near
retention measurements.

## Device evidence

The legacy report records EDIFIER M60 stereo float32 shared-mode output at
96 kHz, rendered from a mono 48 kHz DSP/reference stream. It records one
`record` microphone acquisition with AGC, noise suppression and echo
cancellation configuration flags set to false, but does not identify which input
endpoint was selected.
A read-only Windows endpoint inventory after SSH returned shows Realtek Audio
and DualSense headset microphone endpoints available, plus EDIFIER, Realtek,
controller and display output endpoints. Availability does not identify the
active recording endpoint. No speaker playback, device selection, settings
change or software installation was performed for this diagnostic.

A subsequent read-only MMDevice default-endpoint query identifies the current
Console, Multimedia and Communications capture endpoint as the DualSense
Wireless Controller microphone. Console/Multimedia render defaults are EDIFIER
M60; Communications render is the controller. This establishes current defaults,
not which endpoint was active when the legacy file was captured. Capture
`FxProperties` registers `VocaEffectPack`; render properties register Microsoft
Audio Home Theater Effects. Effect registration alone does not establish whether
processing is enabled, and no explicit disable-system-effects value appeared in
the inspected properties. A new trial must log and select the recording endpoint
explicitly. No endpoint or enhancement setting was changed.

`record_windows` 2.3.0 source inspection shows that these three flags are parsed
and retained in `RecordConfig` but not used by the Windows capture implementation.
`CreateAudioCaptureDevice` sets only Media Foundation audio-capture source type
and optional endpoint ID before `MFCreateDeviceSource`. Its source reader sets
only the asynchronous callback attribute. There is no RAW/device-effect bypass
request in this path. Therefore the false flags must not be interpreted as
proof that Windows endpoint APOs or microphone firmware DSP were bypassed.
