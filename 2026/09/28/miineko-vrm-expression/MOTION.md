# Silent mouth-motion preview

## Scope

This stage drives the accepted `mouth-aa-aligned` VRM without changing its
geometry or materials. It adds two editable playback choices in the local viewer:

- **母音を順に確認:** five separate openings with closed intervals (5.5 s loop).
- **会話風（無音）:** authored vowel crossfades, changing opening strengths and
  pauses (4.1 s loop). It is not extracted from speech and has no audio track.

Open `viewer.html?model=mouth-aa-aligned&motion=1`. Play/pause, stop-to-close,
speed (0.5×/1×/1.5×), strength and a position slider are available. Eye/relaxation
controls and the original-model toggle still work. Manual mouth edits stop the
preview. A hidden document pauses mouth playback to avoid a jump when returning.
Stopping keeps the chosen mode/speed/strength but resets position and closes
the mouth. Natural blink has its own control and clock.

The `motion=1` opt-in keeps the older comparison layout and canvas size intact
for the existing screenshot-based checks. This is a runtime preview; it does not
write an animation into the VRM or require a new VRM export.

## Driver contract

`scripts/mouth_motion.mjs` contains the authored timelines, smooth interpolation,
weight normalization and playback clock. The viewer sends the resulting five
weights through the existing VRM expression manager. It does not re-create the
mouth effect with a custom shader. Adjacent keyframes are interpolated with a
smoothstep curve, including the closing/reopening intervals and loop boundary.

Weights must be finite, nonnegative and total at most one. The normalizer drops
invalid values and scales large vectors safely; it preserves ratios when total
weight exceeds one. Preview strength multiplies the normalized result. Clock
changes preserve position across pause/resume and speed changes, and stale frame
timestamps do not rewind the clock. These are driving constraints of this
surface method, not automatic guarantees supplied by VRM.

## Validation (2026-09-28)

Run `mise run motion-probe` after installing the existing Node dependencies and
preparing the accepted model plus `base-vrm.vrm`. Node's built-in test runner
checks weight bounds, both complete loops, crossfades and clock controls. The
independent browser test checks 121 sampled times in the actual VRM, a known
AA/IH blend, simultaneous mouth motion and blink, pause, manual takeover,
original-model toggling and exact framebuffer restoration after stop.

Desktop (1280 px), compact (600 px) and narrow (390 px) layouts were inspected;
all fit without horizontal scrolling. The preview camera also keeps the head
inside a narrow canvas, without changing the static comparison framing. Browser screenshots and the detailed
report are local in `artifacts/mouth-motion/`. Compact numerical evidence is in
[results/mouth-motion-evaluation.json](results/mouth-motion-evaluation.json).
The existing static expression viewer checks also pass after the control change.

The accepted VRM remains SHA-256
`cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31`.
This work uses JavaScript only; it does not run Pillow or rebuild the model.
The prior Pillow update trial changed historical atlas PNG bytes, so the
existing comparison pin is retained under the lab's parity policy. Migration
remains separate from this motion test; no dependency versions were changed.

## Next verification

The next [audio-backed test](AUDIO.md) now covers known synthesized vowel cues,
measured energy, pause/seek/rate controls and the audio playback clock. Artistic
timing and arbitrary-speech inference still need evaluation, along with physical
audio/display latency and sustained mixed expressions in the intended application. The synthetic preview, scripted
blink overlap and sampled weight bounds do not certify phonetic correctness,
all possible geometry combinations, additional emotions, gaze or spring motion.
