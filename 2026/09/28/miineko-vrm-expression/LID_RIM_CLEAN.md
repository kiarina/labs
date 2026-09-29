# Remove circular dark traces around the closed eyes

## Request and result — 2026-09-29

The owner pointed to the circular dark trace where the original open eye had
been, using blink .86 as the reference. The new `lid-rim-clean` candidate removes
the copied dark flecks from the pink lids while retaining the intentional black
closed-eye line. It builds on [highlight-clean-r](HIGHLIGHT_CLEAN.md) and does not
replace the accepted private assets snapshot. The owner found the frontal result improved and requested the remaining
oblique fragments be corrected; continue with [LID_ENVELOPE.md](LID_ENVELOPE.md).

Open `expression-study.html?variant=lid-rim-clean&blink=.86&opening=0&angle=0`.
Compare with `highlight-clean-r` at the same strength and camera. Partial closure,
full blink, happy, angry, sad and relaxed are included in the review captures.

## Diagnosis

The small dark marks survived disabling the underlying normal maps, increasing
lid opacity, flattening lid lighting, and moving lids slightly forward. A solid
white diagnostic lid hid them, and replacing just lid vertex RGB with a uniform
pink also removed them while retaining the original lighting. The principal
circular flecks were therefore **inherited lid color**, not a depth-overlap or
normal-map problem. The original lid builder copied pink-classified texels near
the eye; some still included the original eye boundary's dark discoloration.

This is a different cause from the preceding highlight's vertex-normal stain.
A plausible visual resemblance is not enough to reuse the same correction.
`scripts/inspect_lid_rim.mjs` preserves the diagnostic comparisons; its temporary
uniform color, opacity and depth changes are not part of the delivered model.

## Local vertex-color repair

`scripts/refine_lid_rim.py` modifies only RGB in the four fixed upper/lower pink
lid meshes. For each eye it samples the existing vertex colors on the outer-skin
annulus, normalized radius 1.08–1.30. Spatial bins prevent densely tessellated
patches from dominating. A robust quadratic color field is fitted in linear RGB,
using 582/571 retained bins for the current input. It replaces the inner color
field through radius 1.03 and smoothly rejoins the original values by radius 1.22.

Alpha values remain bit-identical in the runtime U16 color accessors. Positions,
normals, UVs, indices, source face colors/textures, ink layer, all expression
bindings, mouth and ears are unchanged. The runtime file appends four replacement
color accessors without rewriting earlier binary bytes. The matching colors are
saved in a copied blend. No bitmap is repainted and no new face geometry is added.

The fit is a model-specific construction, not automatic skin reconstruction.
It removes local dark color contamination; the larger skin-color/material join
and occasional oblique slivers are still visible. In particular, the inherited
small black/white slivers in the oblique full-smile view are not repaired here.
Do not describe this as seamless skin or a cure for all closed-eye artifacts.

## Reproduce and evidence

Prepare the preceding [highlight input](HIGHLIGHT_CLEAN.md), with pinned tools in
[BASELINE.md](BASELINE.md), then run:

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run lid-rim-probe
```

Outputs are `artifacts/lid-rim-clean`, `-repeat`, and `artifacts/lid-rim-review`.
The optional diagnostic requires the existing local viewer server and runs with
`node scripts/inspect_lid_rim.mjs` from the lab directory.

- [Structure](results/lid-rim-structure.json): only four lid RGB accessors change;
  alpha and all other runtime data are preserved. Saved blend geometry, normals,
  UVs and alpha match the source. Repeated runtime output is byte-identical.
- [Runtime](results/lid-rim-evaluation.json): 90 source/candidate states in five
  views, including .25/.86/full closure and emotion endpoints, plus open-eye
  mouth/ear coexistence and three viewport widths. The front and two other
  open-eye views match exactly; 45° has 3 changed pixels (maximum 8/255), and
  90° has 1 (maximum 2/255), from inherited subpixel neutral coverage. The audit
  bounds this drift to at most 4 pixels and 8/255; it does not call it exact parity.
- [Image measure](results/lid-rim-pixels.json): high-frequency dark residuals in
  the selected frontal top/bottom rim bands at .86 fall from 936 pixels to zero.
  This fixed-camera metric is not proof of no artifact under every condition.
  The dark-ink masks differ by 0–2 edge pixels across six frontal poses; the
  actual ink geometry and alpha are unchanged.

This cleanup and its oblique-gap successor are included in [version 1](VERSION_1.md).
Treat remaining skin joins
and oblique gaps as distinct corrections, retaining the current eye-line shape,
head silhouette, nose and mouth weight.
