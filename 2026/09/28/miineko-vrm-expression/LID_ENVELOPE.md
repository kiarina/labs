# Cover the eye fragments exposed in oblique closed-eye views

## Request and comparison — 2026-09-29

The owner found the frontal circular-trace cleanup improved, but supplied
±45° full-blink screenshots with small black/white fragments above the closed
eye. `lid-envelope` addresses those gaps, building on [LID_RIM_CLEAN.md](LID_RIM_CLEAN.md).
The owner accepted this result and fixed it as [version 1](VERSION_1.md).
The final assets snapshot is `miineko/vrm/miineko.{blend,vrm}`.

Open `expression-study.html?variant=lid-envelope&blink=1&opening=0&angle=-45`.
The viewer now includes 15° increments through both profiles. Compare against
`lid-rim-clean` at the same view/weight. The larger skin-color/material boundary
is still a separate finishing issue; this change targets the small exposed flecks.

## Diagnosis and discarded approaches

Ray intersections in the original 45° view found the body eye surface ahead of
the upper lid at the white fragment. Copied eye geometry contains folded or nearly
vertical facets: a forward translation of a copy is not a conservative cover
when viewed from the side. This is distinct from the prior RGB-contamination ring.

Uniformly moving the lids forward reduced but did not eliminate the fragments.
Double-sided rendering alone did not fix them; expanding the lids made the white
opening worse. Winding changes alone also left a fragment. These diagnostics
are not the delivered correction. A narrow foreground-depth sampling footprint
removed most gaps but left a thin remnant; the final footprint below covers it.

## Construction and protected data

`scripts/refine_lid_envelope.py` casts toward the original body from the front to
find its foremost surface at each existing lid vertex's x/height position. It
uses the maximum foreground depth in a 3×3 neighborhood with offsets −.002, 0,
+.002 model units. This guards against a crease falling between samples. The
existing offsets remain: upper .0007, lower .0004, upper ink .0009. Both the skin
and ink surfaces use the same underlying envelope so their relationship stays
consistent. Maximum depth correction is about .0125/.0129 units on the two eyes;
it is local replacement of folded depth, not a uniform forward displacement.

Only the depth coordinates of the six existing lid/ink meshes change. Front x/y,
vertex/triangle counts, winding, normals, colors, alpha, UVs, textures, skinning
and all expression bindings are retained. The original body/head, source eyes,
highlight repair, nose, mouth and ear morph are unchanged. The skin-normal field
was already fitted to the surrounding face; it is preserved in both artifacts.
A KD-tree matches exported x/height positions to authoring vertices within 2e-6,
so the saved blend uses the exact runtime depth samples instead of re-casting
slightly different float coordinates near a discontinuity.

This is calibrated to this model and tested view range. It is not a universal
occlusion proof, a new neutral head shape, or a guarantee under arbitrary
skinning/lighting. Full-body motion of this new candidate has not been rerun.

## Reproduce and evidence

Prepare `lid-rim-clean` and the pinned tools in [BASELINE.md](BASELINE.md):

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run lid-envelope-probe
```

Artifacts: `artifacts/lid-envelope`, `-repeat`, and `artifacts/lid-gap-review`.

- [Structure](results/lid-envelope-structure.json): only six depth accessors and
  buffer metadata change. All original bytes are retained, repeat output matches,
  original body positions are unchanged and saved blend positions match runtime.
- [Runtime](results/lid-envelope-evaluation.json): 234 source/candidate captures,
  13 angles from −90° to +90°, partial/full blink and emotion endpoints, open-eye
  ear/mouth coexistence and three viewport widths.
- [Fragments](results/lid-envelope-fragments.json): no black/white fragment pixels
  remain in the designated band above the closed-eye line in 78 angle/pose cases.
  That band covers the reported defects; it is not a whole-image cleanliness test.
- [Front ink](results/lid-envelope-ink.json): all six tested frontal dark-ink masks
  match the preceding model, including .86 and full closure.

Open-eye front/±15°/−30° captures match exactly. Other open views differ at up to
12 pixels, maximum 53/255, due to inherited tiny neutral coverage becoming visible
at shifted depths. The audit explicitly bounds this residual rather than claiming
all-view pixel parity. The final copy is recorded in [VERSION_1.md](VERSION_1.md); earlier snapshots are retained.

Further skin-color/material transition work belongs to a later revision,
preserving this version 1 checkpoint and the accepted eye-line shape and motion.
