# A continuous greeting with authored mouth timing

## Question and result

Can the accepted mouth shapes transition during a short continuous utterance,
close during its pause and ending, and coexist with blinking and relaxation?
The new preview uses 「こんにちは、みぃねこです。」 spoken in a single synthesis
call. It is not assembled from isolated syllables. The timing is an authored,
approximate animation profile for this recording, not recognized phonemes or
ground-truth alignment. Kyoko remains a temporary voice.

Open `viewer.html?model=mouth-aa-aligned&motion=1&audio=greeting` and press
**音声と口を再生**. The **音声** selector returns to the five-vowel test.
Playback stays opt-in and supports the existing speed, strength, volume, seek
and pause controls. The model file is unchanged.

## Reproduce

Use the existing private model, Node dependencies and macOS Kyoko voice from
[BASELINE.md](BASELINE.md) and [AUDIO.md](AUDIO.md). No dependencies were added.

```sh
python3 scripts/build_greeting_audio.py
SPEECH_RUN=speech-greeting-repeat python3 scripts/build_greeting_audio.py
mise run greeting-probe
# Existing regression fixtures must already be prepared as described in AUDIO.md.
mise run audio-motion-probe
mise run motion-probe
```

Generation replaces files only in the chosen speech output directory. The script
checks raw WAV bytes against `fixtures/greeting-timing.json` before producing
the manifest. A changed OS voice must be evaluated and assigned a new timing
profile; changing the expected hash alone does not establish valid alignment.
Generated audio, model files and captures remain local and ignored by Git.

## Timing and rendering

The raw recording is 2.036644 s at 22,050 Hz, mono 16-bit PCM. The preview adds
350 ms of leading silence and 500 ms at the end, for 2.886621 s total. Exact
text, synthesis arguments, OS version, hashes and RMS settings are recorded in
the generated manifest. Two local generations matched in WAV and manifest bytes.

The tracked profile specifies approximate mora intervals against that exact raw
recording. Its pause lies between the two clauses. A closed-mouth cue represents
the authored nasal/m onset motion, and the final 「す」 has gain 0.2. These are
cartoon animation choices, not a general rule that every nasal requires closure.
RMS controls strength but cannot identify the vowel.

Version 2 of the audio manifest supports closed cues, per-cue gain and a 60 ms
smooth transition between touching cues. Each transition is shortened for very
short intervals. At a real gap the mouth fades to zero over 20 ms rather than
carrying the previous shape into silence. The previous version 1 vowel fixture
retains its original sampling behavior. Both versions use the audio element's
`currentTime`, with finite nonnegative weights totaling at most one.

## Evidence — 2026-09-28

[results/greeting-motion-evaluation.json](results/greeting-motion-evaluation.json)
records 145 sampled states, including 13 with multiple active vowels. The largest
total weight was 0.8. A live 178-frame playback visited all five vowel shapes,
overlapped blinking and ended closed. Pause, half-speed resume, the clause pause,
the ending, and switching back to the five-vowel fixture passed. Front, oblique,
both side views and 1280/600/390 px layouts were inspected. Unit checks also
sample every millisecond for transition continuity and closed intervals.
Existing audio and silent preview regressions passed; the silent stop restored
the neutral framebuffer exactly. These checks establish driving behavior, not
perceptually correct phoneme timing or physical speaker/display latency.

The accepted VRM SHA-256 remains
`cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31`.
Raw greeting WAV: `4764d1419c4668f8db4ff06dadec99f93743ddc2e927d5df68df27398969f933`.
Padded greeting WAV: `66fc9c029786d5f5228f32aca5544d991d4a3f522826edf51864b42b86016fda`.

## Attempted marker route and limits

Before authoring the profile, `scripts/probe_speech_markers.swift` tested Apple's
audio-buffer and synthesis-marker callbacks with the installed compact Kyoko
voice. It returned 40,856 audio frames and zero markers on macOS 26.6.2. This
probe uses the native API's default rate, separately from the `say -r 140`
fixture; it does not claim frame parity or that other voices cannot return markers.
Run `swift scripts/probe_speech_markers.swift` to repeat this diagnostic.

Apple documents [synthesis markers](https://developer.apple.com/documentation/avfaudio/avspeechsynthesismarker)
as carrying metadata including phonemes and offsets. The older
[NSSpeechSynthesizer phoneme callback](https://developer.apple.com/documentation/appkit/nsspeechsynthesizerdelegate/speechsynthesizer(_:willspeakphoneme:))
is restricted to MacinTalk voices. We therefore did not assume either interface
would provide Japanese phoneme timing for this fixture.

Next review the greeting's appearance and add a small set of comic emotions.
If automatic speech driving is required, evaluate synthesis-provided durations
or forced alignment on multiple held-out sentences. Do not expand hand-tuned
sentence profiles into an apparent general recognizer. The final character voice,
microphone/streaming input, phonetic correctness, physical AV latency, gaze and
spring integration remain unresolved.
