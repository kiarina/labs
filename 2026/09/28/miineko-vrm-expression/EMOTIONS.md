# Separate relaxed curved eyes from straighter sad eyes

## Current owner feedback — 2026-09-29

The owner accepted the angry direction, with possible later angle refinement.
The preceding sad expression read as **relaxed**, so it is reassigned to that
preset without changing its appearance. For sadness, the owner requested raised
inner corners with much less arc, referring to the sticker sheet's left column,
sixth row. The current candidate is **`eye-emotions-straight`**. The new sad shape
has not yet received owner feedback. Happy and angry remain accepted references.

Open `expression-study.html?variant=straight-sad&sad=1&opening=0&angle=0`.
The four 100% buttons select happy, angry, sad or relaxed individually. Sliders
allow intermediate strengths and mixtures. The slow cycle includes all four
emotions. Mouth control is independent. The previous `eye-emotions` model remains
available as a comparison, including its former upper-lid-only relaxed expression.

## Current change and constraints

`scripts/refine_sad_expression.py` reads `eye-emotions` and copies its former
`sad` preset **exactly** into `relaxed`. It then lowers the sad curve coefficient
from .024 to .008, retaining the ±.28 central slope, full central band gap, and
raised inner corners. This is a substantially straighter appearance, not a claim
of mathematically zero curvature. The existing parabolic reveal material is
reused; angle and center compensation are recalculated for the lower curvature.

Only the `sad` and `relaxed` JSON preset objects change in the exported VRM.
The binary chunk, all other JSON fields, geometry, textures, happy, angry,
blinking and mouth bindings remain unchanged. The matching new binds are saved
to a copy of the authoring blend. No highlight darkening, new meshes, tear marks,
eyebrows, or mouth frowns are added. Existing skin-color/perimeter artifacts remain
visible and are still deferred rather than being described as fixed.

The old relaxed eye was a half-lid expression. It is preserved in the previous
model, not deleted from the experiment history. Current relaxed means the curved
closed-eye shape that the owner identified as relaxed.

## Shared construction and driver contract

The original `scripts/add_eye_emotions.py` added the first angry/sad directions to
the accepted `sync-smile` VRM, replacing only their empty preset objects. That
step and its artifacts remain the input to the current refinement. The accepted
smile stays unchanged throughout both stages.

The four fixed pink lids use a parabolic reveal texture. For local eye coordinate
`x`, radius `r=.104`, base rise `k0=.004`, scale `s`, and translation `q`, the edge
contributes `-k0*(s*x/r+q)^2`. Choosing `s=sqrt(k/k0)` and
`q=-m*r/(2*k0*s)` supplies slope `m`. V compensation removes the constant
`k0*q^2` at full strength. Angry has lower inner corners; relaxed and sad have
higher inner corners. Their mirrored slopes are checked in front-view images.
The optional upper-ink binds remain inactive to avoid a duplicated line.

This is not rigid rotation of the whole eye. At partial strength the translated
parabola has a small nonlinear center shift. Reducing k increases that effect:
for the new sad parameters its maximum is approximately .0066 model units,
compared with .0022 for the preceding .024-rise shape. The existing smile's exact
onset/7:3 measurements must not be attributed automatically to these emotions.
Intermediate appearance still needs artistic evaluation.

The viewer normalizes happy/angry/sad when their sum exceeds one and multiplies
them by `(1-blink)`. Relaxed receives the remaining emotion contribution; blink
retains its own weight. This existing priority is unchanged, so relaxed is not
weighted symmetrically with the other three when sliders are combined. The
100% buttons avoid ambiguity for single-expression comparison. Other consumers
must implement the same driver contract. New presets use `override*=none`.

## Reproduce

Use the pinned tools and source chain in [BASELINE.md](BASELINE.md),
[CONNECTED_VOWELS.md](CONNECTED_VOWELS.md), and [BALANCED_SMILE.md](BALANCED_SMILE.md).
Prepare the original `eye-emotions` reference first if it is absent:

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run eye-emotions-probe
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run straight-sad-probe
```

The current task writes `artifacts/eye-emotions-straight` and `-repeat`, with
captures in `artifacts/straight-sad-review`. The prior task writes its separate
`eye-emotions` folders. Private binary/bitmap artifacts remain ignored. GUI
re-export of the blend is not the validated runtime artifact; previous export
patches remain applicable.

## Current evidence

- [Structure/import](results/straight-sad-structure.json): binary chunk and JSON
  outside sad/relaxed are unchanged. Relaxed equals the former sad preset exactly.
  Saved/imported binds agree; separate generated VRMs match byte-for-byte.
- [Runtime](results/straight-sad-evaluation.json): 45 retained-expression/mouth
  views match the prior model, and 20 new-relaxed views match its former sadness
  at the same strength. 120 new sad/relaxed states, 81 mixtures, four one-click
  presets, live cycle, reset and 1280/600/390 px layouts are checked.
- [Shape](results/straight-sad-shape.json): the front-view largest eye bands retain
  raised inner corners. Estimated rise drops from about .024 to .008; deviation
  from a fitted straight line in the central sample falls from approximately
  3.1–3.2 px to 1.3–1.4 px. Bright-white count is zero at both full endpoints.
  These are raster checks, not proof that the sad expression conveys the intended
  feeling or that every view is free of the inherited edge artifacts.

The preceding stage's observations remain in
[structure](results/eye-emotions-structure.json),
[runtime](results/eye-emotions-evaluation.json), and
[shape](results/eye-emotions-shape.json). They apply to the earlier two tilted
presets, not the new sad/relaxed meaning.

## Next work

Evaluate whether the straighter raised-inner-corner eyes read as sadness and
remain distinct from relaxed throughout the transition. Keep accepted happy and
angry intact. Angle refinements, 7:3 tuning, skin-color seams and mouth/audio
response can follow the basic expression set. Gaze, springs, full-body poses,
target-runtime checks and end-to-end generation remain open.
