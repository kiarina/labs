# Preserving a Tripo VRM face while adding expressions

## Current result — 2026-09-29

The owner accepted the manga-like eyelid overlay, relaxation, and five cartoon
vowel shapes while retaining the original Tripo head. The combined comparison
baseline is `artifacts/mouth-aa-aligned/continuous-blink.vrm`. It is not yet a
production-complete avatar. A [silent mouth-motion preview](MOTION.md) exercises
vowel transitions and pauses; an [audio-backed vowel test](AUDIO.md) now drives
the same shapes from known cues and measured energy on the audio playback clock.
A [continuous greeting preview](SPEECH.md) adds authored timing and smooth vowel
transitions; the owner found the greeting natural. A [smile-eye candidate](HAPPY.md)
was rejected for its protruding, bulb-like closed eyes. The current direction is
a [feature-depth study](FEATURE_DEPTH.md): preserve the pink head geometry and
nose while reducing only eye/W depth. The broader [thin-face study](THIN_FACE.md)
was rejected because it changed the head profile. The old baseline remains the
input and comparison reference. The current [mouth-depth candidate](MOUTH_FLUSH.md) includes
the joining band and vertical line while retaining the original line weight. The
owner found this improved; a [connected AA opening](CONNECTED_AA.md) now tests
the red interior and lower-contour connection against the sticker reference. The owner
approved that direction. A [five-vowel extension](CONNECTED_VOWELS.md) now adds
wide/shallow and narrow/round openings plus continuous transitions. Arbitrary
speech-to-vowel inference is still unimplemented.

**Start with [BALANCED_SMILE.md](BALANCED_SMILE.md)** for the current priority:
validate upper-led smile closure with the original highlight, blink and relaxed expressions before
mouth/audio polish. The
prototype reduces inherited eye-bulb shading but still has visible color/perimeter
artifacts and is not an accepted finished face.
[BASELINE.md](BASELINE.md) records the earlier accepted artifact,
prerequisites, ordered rebuild recipe, limitations, and lessons to carry forward.
Keep new experiments in separate output directories. Character designs, source
FBX/textures, blends, VRMs and screenshots are private and excluded from Git.

## Documentation map

| Document | Purpose |
| --- | --- |
| [BALANCED_SMILE.md](BALANCED_SMILE.md) | Current upper-70/lower-30 closure trial; preserve highlight color and evaluate intermediate motion. |
| [CRESCENT_SMILE.md](CRESCENT_SMILE.md) | Earlier broad smile; owner found the lower-lid lift and darkened highlight frightening. |
| [ROUNDED_SMILE.md](ROUNDED_SMILE.md) | Earlier short-arc candidate; 100% was rejected as too thin and mismatched to eye size. |
| [SURFACE_EXPRESSIONS.md](SURFACE_EXPRESSIONS.md) | Earlier expression diagnostic, fixed lids, shading control and remaining color/perimeter issues. |
| [CONNECTED_VOWELS.md](CONNECTED_VOWELS.md) | Current five-vowel probe, shared-surface mixtures, onset response and validation. |
| [CONNECTED_AA.md](CONNECTED_AA.md) | Accepted AA-only opening, source-W connection, closed recovery and validation limits. |
| [MOUTH_FLUSH.md](MOUTH_FLUSH.md) | Current mouth/vertical-line depth adjustment; original stroke weight and nose retained. |
| [FEATURE_DEPTH.md](FEATURE_DEPTH.md) | Earlier eyes/W interior adjustment and strict pink-boundary protection. |
| [THIN_FACE.md](THIN_FACE.md) | Rejected broad face deformation; retains historical static comparison and measurements. |
| [BASELINE.md](BASELINE.md) | Earlier accepted appearance and motion baseline; retained for comparison and reproduction. |
| [HAPPY.md](HAPPY.md) | Rejected raised-eye smile; emotion/blink composition and measured repeatability. |
| [SPEECH.md](SPEECH.md) | Continuous greeting, authored timing, vowel transitions and repeatability. |
| [AUDIO.md](AUDIO.md) | Local test voice, known vowel cues, audio-clock playback and validation limits. |
| [MOTION.md](MOTION.md) | Silent playback controls, normalized driving contract and runtime checks. |
| [EXPERIMENTS.md](EXPERIMENTS.md) | Continuous blink alternatives, eye selection, and relaxation evidence. |
| [MOUTH.md](MOUTH.md) | Initial black/pink AA probes; historical zero-area neutral method. |
| [VOWELS.md](VOWELS.md) | Red mouth, five-vowel and flat-onset experiments; early failures retained. |
| [PROFILE.md](PROFILE.md) | Depth fitting, source-lip occlusion, per-vowel refinements and final owner acceptance. |
| [EARLY_EXPERIMENTS.md](EARLY_EXPERIMENTS.md) | Rejected whole-head, full-mask and two-tile atlas routes, with their original measurements. |
| [results/](results/) | Numerical evidence; test success alone is not artistic acceptance. |

The old `reproduce`, mask and atlas tasks are diagnostic reproductions of those
historical routes. They are not the path to the accepted face.

## Remaining work

The revised normal face and connected AA direction are accepted. Evaluate the new
eye expressions first; mouth/onset/audio polish is deferred by owner request.
Then integrate speech, gaze and SpringBone. Then
validate the combined result in the intended runtime and review export metadata
before distribution. Binding reimport, screenshot checks and owner approval of
mouth shapes do not certify all poses, all runtimes or audio synchronization.

## Documentation-only/static check

```sh
mise run
```

This compiles the scripts and checks the recorded UV inspection. It does not
rebuild or visually validate a VRM. Runtime reproduction requires private input;
follow [BASELINE.md](BASELINE.md).
