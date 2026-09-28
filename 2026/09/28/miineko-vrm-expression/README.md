# Preserving a Tripo VRM face while adding expressions

## Current result — 2026-09-29

**The current working baseline is `artifacts/surprise-ears/continuous-blink.vrm`.**
The owner provisionally accepted the mouth-plus-raised-ear surprise on 2026-09-29.
Start with [SURPRISE_EARS.md](SURPRISE_EARS.md) for its construction, source chain,
reproduction and limitations. It contains the preceding accepted face and basic
expressions; it is not a production-complete avatar.

| Part | Current decision | Canonical detail |
| --- | --- | --- |
| Head, nose and normal face | Retain the pink head and protruding nose; fit black eyes, W and vertical mouth line to the surface without thinning their strokes. | [MOUTH_FLUSH.md](MOUTH_FLUSH.md) |
| Mouth | Connected red interior and lower outline; five vowels on one fixed surface. Small-opening response still needs polish. | [CONNECTED_VOWELS.md](CONNECTED_VOWELS.md) |
| Happy | Shared upper/lower onset, approximately 7:3 travel; white highlight stays until covered. Accepted minimum quality. | [BALANCED_SMILE.md](BALANCED_SMILE.md) |
| Angry / relaxed / sad | Angry accepted; former curved sad reassigned to relaxed; steeper straight-looking sad provisionally accepted. | [EMOTIONS.md](EMOTIONS.md) |
| Surprised | Normal round eyes, OH mouth plus raised ears; provisionally accepted. Ears are independent of blink and mouth. | [SURPRISE_EARS.md](SURPRISE_EARS.md) |
| Speech | Natural greeting was reviewed on the **older** `mouth-aa-aligned` model. It has not been integrated with this revised face. | [SPEECH.md](SPEECH.md) |

The sticker sheet guides character expression rather than requiring exact copies.
Rejected experiments remain documented for comparison: broad head smoothing,
raised closed-eye volume, thin smile arcs, highlight darkening and surprise eye
narrowing. Their scripts and old acceptance records do not override this table.
[BASELINE.md](BASELINE.md) records the earlier `mouth-aa-aligned` source and its
rebuild route. Keep new experiments in separate output directories. Character
designs, source FBX/textures, blends, VRMs and screenshots are private and excluded
from Git; pulling this repository alone does not provide the model.

## Documentation map

| Document | Purpose |
| --- | --- |
| [SURPRISE_EARS.md](SURPRISE_EARS.md) | Provisionally accepted raised-ear surprise; source chain, original eyes, independent mouth and blink. |
| [SURPRISE.md](SURPRISE.md) | Rejected eye-narrowing comparison and mouth-only reference. |
| [EMOTIONS.md](EMOTIONS.md) | Current curved-relaxed/straighter-sad split; accepted happy and angry preserved. |
| [BALANCED_SMILE.md](BALANCED_SMILE.md) | Accepted minimum-quality smile baseline; shared onset, upper/lower ratio, remaining limits. |
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

The basic expression directions have been reviewed. Next check transitions and
how quickly the ears rise, then integrate the chosen driving behavior. Fine
mouth/onset/audio tuning is a separate follow-up, not a reason to reopen the
accepted face. Skin-color/perimeter seams and exact eye ratios remain unresolved.
Gaze, SpringBone, full-body poses, target-runtime checks and a fresh end-to-end
rebuild from the private FBX are still required. Review export metadata before
distribution. Stage-by-stage repeatability and appearance approval do not certify
all poses, all runtimes or audio synchronization.

## Documentation-only/static check

```sh
mise run
```

This compiles the scripts and checks the recorded UV inspection. It does not
rebuild or visually validate a VRM. Runtime reproduction requires private input;
follow [BASELINE.md](BASELINE.md).
