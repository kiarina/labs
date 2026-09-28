# Close mainly from the upper lid and preserve the highlight

## Current direction — 2026-09-29

The owner found the [crescent smile](CRESCENT_SMILE.md) frightening and suggested
that the lower lid rose too far/too early while the upper lid lagged. The owner
also asked to retain the highlight until the upper lid naturally covers it,
using approximately **upper 70% / lower 30%** closure as a starting point. This
supersedes freezing the former 92% shape and darkening its remaining highlight.
It is an artistic trial ratio, not a physiological rule or a finished design.

Open `expression-study.html?variant=balanced&happy=.5&opening=0&angle=0`.
The new endpoint and 25/50/75% transitions can be compared with the preceding
lower-lid-heavy/darkened-highlight candidate. The body, nose and mouth remain
unchanged. Existing pink-lid color and perimeter artifacts remain visible; the
candidate has not been accepted by the owner.

## How closure is defined

The builder samples source eye artwork along each eye's center column, at .00025
model-unit intervals. Achromatic black/highlight texels determine the visible
upper and lower limits. It does not use the much larger invisible lid shell as
the measure of eye height. Current sampled bounds are .69425/.52525 (L) and
.69425/.52550 (R).

Add .001 of neutral clearance above/below those bounds and retain a .024-wide
vertical gap at full happiness. Allocate 70% of the remaining travel to the upper
lid and 30% to the lower. After subtracting invisible clearance, the central
visible upper shares are approximately .70276. This is **central vertical travel**,
not the fraction of the entire eye area covered. Curvature changes the ratio away
from the center, so do not claim a uniform 7:3 split over every column.

The former high/low sweep origins delayed actual contact with the eye. Origins
now come from these measured bounds. Neutral UVs are clamped just below the reveal
threshold, including curvature, to suppress peripheral cover at zero. The measured tiny residual is recorded below.
This makes both lids begin acting earlier. The full smile uses rise coefficient
.055 rather than the old .1056784; the closure band is lower on the face and its
width/curve consequently differ from the former 92% snapshot. Preserving that
snapshot exactly is no longer the objective.

All positions remain fixed source-triangle layers. The highlight fill is absent;
there are **no happy material-color binds**. The original eye materials/textures
are unchanged. The extra upper ink remains inactive during a pure smile. Only
pink lid reveal masks hide the highlight. The source highlight therefore keeps
its original color in uncovered pixels, rather than fading toward gray/black.

Blink and relaxed full edge positions remain at their earlier levels, but use
the new per-eye origins and neutral clamp; their onset is not claimed identical.
The normalized eye-weight driver and independent vowel control remain as in
[SURFACE_EXPRESSIONS.md](SURFACE_EXPRESSIONS.md). A .030-rise exploratory version
looked too flat at the endpoint; the final comparison uses .055. This is still a
visual candidate rather than a claim that the expression is no longer frightening.

## Reproduce and checks

Prepare the input and controls using [BASELINE.md](BASELINE.md),
[CONNECTED_VOWELS.md](CONNECTED_VOWELS.md), and the preceding expression studies.
Use the pinned Blender/VRM add-on, Node and Python versions.

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run balanced-smile-probe
```

Outputs replace only `artifacts/balanced-smile` and `-repeat`, with captures in
`artifacts/balanced-smile-review`. Models, screenshots and source audits stay
private/ignored. Existing candidate binaries are retained for comparison.

- [Geometry and bindings](results/balanced-smile-geometry.json): unchanged source
  body coordinates and vowel binds, fixed source-following planes, per-eye travel
  calibration, six texture binds per bilateral eye preset and no black fill or
  happy color bind after reimport.
- [Visible motion](results/balanced-smile-motion.json): front-view central lid
  displacement at 25/50/75/100%, source bright pixels that remain exactly unchanged,
  and highlight disappearance through occlusion. This measures a small central
  image region, not all poses/views or subjective naturalness.
- [Runtime](results/balanced-smile-evaluation.json): zero-eye comparison with the
  source for five vowels at five angles in two candidates, 120 expression/view
  samples, 27 mixed weights, live cycle, reset, three widths and repeat-byte parity.

## Observations and failed strict checks

In the fixed frontal captures, central upper shares over 25/50/75/100% are
approximately 70.6–71.8%; at full strength they are 70.8% (L) and 70.6% (R).
At 50%, 993/1,142 source bright pixels remain exactly unchanged. At 75% and
100%, the frontal bright count is zero, with no color bind or black fill.

A strict zero-state pixel test initially failed near the eye edges. Increasing
the neutral UV margin from .498 through .49 to .48 reduced the residual; tiny
degenerate triangles are excluded from these new lid layers (the source body
is untouched). This did not eliminate the final single-channel-step difference:
of 50 source comparisons, 45 are exact and five have **one pixel differing by
1/255** at the same right-oblique view, once per vowel. The test records this
and permits at most two such pixels only for this candidate; it does not call
those five comparisons exact. Reset to the frontal initial frame is exact.

The import check also initially confused material names carrying Blender's
`.001` suffix after loading another control blend. It now removes scratch scene
materials before import so canonical names and per-eye bindings can be checked.

## Remaining work

Assess the intermediate motion and full expression before selecting this ratio.
The remaining pink color patch, sharp reveal boundaries, and oblique perimeter
slivers still affect the appearance. Neutral UV clamping can make the peripheral
cover appear early; do not mistake early onset for seamless eyelid shading.
Do not restore black highlight painting to conceal a lid-position problem.
Mouth/audio polish stays deferred. Full pose/skinning, other runtimes, gaze,
SpringBone and end-to-end regeneration remain outstanding.
