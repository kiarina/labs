# Preserving a Tripo VRM face while adding expressions

## Current result — 2026-09-28

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
input and comparison reference. Arbitrary
speech-to-vowel inference is still unimplemented.

**Start with [FEATURE_DEPTH.md](FEATURE_DEPTH.md)** for the current design comparison.
[BASELINE.md](BASELINE.md) records the earlier accepted artifact,
prerequisites, ordered rebuild recipe, limitations, and lessons to carry forward.
Keep new experiments in separate output directories. Character designs, source
FBX/textures, blends, VRMs and screenshots are private and excluded from Git.

## Documentation map

| Document | Purpose |
| --- | --- |
| [FEATURE_DEPTH.md](FEATURE_DEPTH.md) | Current normal-face comparison: pin pink geometry and nose; adjust eyes/W only. |
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

Review the feature-depth normal face while enforcing pink/nose preservation first. Rebuild
expressions on the chosen surface, then integrate speech, gaze and SpringBone. Then
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
