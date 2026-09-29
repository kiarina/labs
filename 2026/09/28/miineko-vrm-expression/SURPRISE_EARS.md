# Surprise through mouth and raised ears

## Current direction — 2026-09-29

The ear/face baseline remains accepted. The later ordinary blink update in
[BLINK_ALIGNED.md](BLINK_ALIGNED.md) and subsequent cleanup are included in the
fixed [version 1](VERSION_1.md), which retains this stage's ears.

The owner rejected the [eye narrowing comparison](SURPRISE.md): the normal eyes
already look wide open. The working design pairs the unchanged normal eyes with an OH mouth and ears
that stand more upright. The owner provisionally accepted this appearance on
2026-09-29. Preserve it as the reference while checking transitions and timing.

Open `expression-study.html?variant=surprise-ears&vowel=oh&opening=.65&surprised=1`.
**耳を立てる** controls the ear shape independently from the mouth. **あれ？** sets
ears .40 / opening .30; **えっ！** sets ears 1 / opening .65. Compare **口だけ**
with **口＋耳をピンと立てる**. The old eye proposal remains explicitly labeled
rejected. The ordinary emotion cycle still exercises the four earlier emotions;
it is not an ear animation. A quick startled timing response is future work.

## Lessons and handoff

- A normally wide-open eye need not become larger or narrower to communicate
  surprise. For this character, the owner preferred changing mouth and ears.
- An emotion is a composition of independently driven features. Keep the ear
  morph separate from blink normalization and vowel weights; the `surprised`
  preset alone does not include the example OH opening.
- Local deformation needs both a protected region and a transition at the root.
  A plausible endpoint is insufficient: inspect intermediate weights, both sides,
  inner-ear surfaces, unchanged face pixels, and neutral recovery.
- A shape-key ear pose is not an ear bone or SpringBone implementation. Preserve
  this reference if later adding physical motion; do not silently substitute a
  new neutral ear shape or couple ear lowering to blinking.
- Match camera and canvas size for comparisons. Fixing percentage-label width
  prevents toolbar wrapping from changing the rendered model scale.

## Implementation and protected regions

The source `eye-emotions-steeper` has no ear bones. The trial uses a standard
morph target, named `Surprise Ears Up`, bound to the VRM `surprised` preset.
No eye-side masks from the rejected model are included. The mouth remains an
independent vowel expression; `surprised` itself contains only the ear morph.

`scripts/build_surprise_ears.py` defines a mirrored 25° inward/upward rotation
around local glTF `(±.20,.915,0)`. The weight fades over .045 units above the
sloped ear-root boundary `y=1.004-.38*abs(x)`, fades in between |x|=.16–.20,
and fades out through |z|=.10–.15. Thus the attachment remains fixed while the
tips rise. This is an art-directed spatial mask, not automatic semantic ear
segmentation. Validate the region again before adapting it to another model.

The central head region |x|<.16, all y<.84, and depth |z|>.15 have exactly zero
position/normal deltas. Both separate eye primitives have zero deltas throughout.
948 exported body vertices move (634 authoring vertices before seam splitting),
with maximum displacement about .0722 model units. Source images, UVs, mesh
positions and other expression presets remain unchanged. Only the new morph
accessors, target metadata and surprised binding are appended to the runtime VRM.
The authoring blend receives the matching shape-key endpoint and expression bind.

Normals use the inverse transpose of the deformation Jacobian. The minimum
sampled endpoint determinant is .677. An initial pivot too far below the ear
root failed the determinant check; it was moved to the attachment region before
producing this candidate. Positive sampled determinants are not a proof against
all self-intersection. Inspect the root and white inner ear across views.
Intermediate VRM morph weights interpolate endpoint positions linearly; they do
not execute a rigid rotation or spring simulation at each weight.

Ear strength is independent of eye-expression normalization and blink. Blinking
must not lower the ears. Happy/angry/sad retain their existing normalized driver,
relaxed uses the remainder, and the mouth retains its nonnegative sum≤1 contract.
Other runtimes must reproduce that control behavior. The rejected eye-only
variant retains its old normalized eye driver for historical comparison.

## Reproduce and evidence

Use the pinned environment and source chain in [EMOTIONS.md](EMOTIONS.md) and
[BASELINE.md](BASELINE.md):

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run surprise-ears-probe
```

The runtime SHA-256 accepted at this checkpoint is
`8db5817cef68c03ef15e915134c8ab06a4e5c1b9e681f5acfbbb888f29d2715c`.
The actual data dependency is:

`mouth-aa-aligned → feature-eyes → feature-mouth-flush → mouth-connected-vowels
→ sync-smile → eye-emotions → eye-emotions-steeper → surprise-ears`.

The first input's private prerequisites are in [BASELINE.md](BASELINE.md).
Use `feature-depth-probe`, `mouth-flush-probe`, `connected-vowels-probe`,
`sync-smile-probe`, `eye-emotions-probe`, `straight-sad-probe`,
`steeper-sad-probe`, then `surprise-ears-probe` for the documented staged route.
`eye-emotions-straight` is a **comparison prerequisite** of the steeper audit;
the steeper builder itself reads `eye-emotions`. `surprise-eyes`, `thin-*` and
`happy-arc` are not inputs to the new ear builder. Run a full-chain rebuild in a
separate workspace; the complete sequence has not yet been validated in one
fresh run. Some tasks overwrite their named output folders.

This writes `artifacts/surprise-ears` and `-repeat` with a blend and runtime VRM,
and private screenshots under `artifacts/surprise-ears-review`. Artifacts stay
ignored. Direct GUI re-export still requires the existing material/sampler
patches; the saved blend is not a promise of identical GUI-export bytes.

- [Structure](results/surprise-ears-structure.json): source binary prefix and all
  pre-existing JSON retained except explicit morph additions; repeat bytes match;
  authoring and VRM-imported shape name, weight and maximum displacement agree.
- [Runtime](results/surprise-ears-evaluation.json): 30 retained views, 50 comparison
  states, 27 combinations including independent blink/ears, a complete silent
  vowel cycle, reset and three layout widths.
- [Image region](results/surprise-ears-shape.json): endpoint image changes stay
  above the face in five fixed views. This is a rendered-region check, not proof
  of semantic segmentation or all-pose safety.

The viewer reserves width for percentage outputs so changing 0%→100% does not
wrap the toolbar and alter the comparison canvas size.

Next: check the timing of the ear rise and transitions using this provisionally
accepted shape. Exact angle/amount refinement can follow those checks.
Skin seams, fine eye/mouth tuning, audio on the new face, gaze, springs and target
runtime integration remain open.
