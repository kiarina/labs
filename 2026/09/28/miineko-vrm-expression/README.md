# Preserving a Tripo VRM face while adding expressions

## Current result — 2026-09-29

**Version 1 is fixed.** On 2026-09-29 the owner accepted `lid-envelope` as the
version 1 checkpoint. Its delivery files are `miineko/vrm/miineko.blend` and
`miineko/vrm/miineko.vrm` in the private assets repository.

Start with [VERSION_1.md](VERSION_1.md) for the exact artifact identity, complete
stage lineage, driving contract, lessons and verification limits. Later work
must preserve this checkpoint and use separate experimental outputs. The earlier
`blink-aligned` snapshot remains a historical reference in the assets history
(`miineko/tripo/v1/` at commit `6d75075`).

| Part | Current decision | Canonical detail |
| --- | --- | --- |
| Head, nose and normal face | Retain the pink head and protruding nose; fit black eyes, W and vertical mouth line to the surface without thinning their strokes. | [MOUTH_FLUSH.md](MOUTH_FLUSH.md) |
| Mouth | Connected red interior and lower outline; five vowels on one fixed surface. Small-opening response still needs polish. | [CONNECTED_VOWELS.md](CONNECTED_VOWELS.md) |
| Blink | Shared-onset, roughly 7:3 closure and thicker shallow line; owner accepted. | [BLINK_ALIGNED.md](BLINK_ALIGNED.md) |
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
| [VERSION_1.md](VERSION_1.md) | Fixed version 1: delivery identity, source chain, behavior contract and post-v1 work. |
| [LID_ENVELOPE.md](LID_ENVELOPE.md) | Version 1 side-view gap repair, foreground depth fitting and 13-angle checks. |
| [LID_RIM_CLEAN.md](LID_RIM_CLEAN.md) | Version 1 circular dark-trace cleanup on closed lids; cause, RGB-only fix, remaining seams. |
| [HIGHLIGHT_CLEAN.md](HIGHLIGHT_CLEAN.md) | Version 1 local highlight-normal cleanup, diagnostic sequence and verification limits. |
| [BODY_MOTION.md](BODY_MOTION.md) | Whole-body checks, dance playback/recording, contact sheet and identified deformation risks. |
| [BLINK_ALIGNED.md](BLINK_ALIGNED.md) | Accepted ordinary-blink correction; movement, thickness and one-shot comparison. |
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

## After version 1

The current deliverables are frozen. [VERSION_1.md](VERSION_1.md) separates the
checked appearance and staged repeatability from later polish, audio, gaze,
springs, target-runtime and full-chain work. The final lid revision has not yet
been through the earlier full-body motion test. Do not continue modifying the
saved version 1 files to address these follow-ups implicitly.

## Documentation-only/static check

```sh
mise run
```

This compiles the scripts and checks the recorded UV inspection. It does not
rebuild or visually validate a VRM. Runtime reproduction requires private input;
follow [BASELINE.md](BASELINE.md).
