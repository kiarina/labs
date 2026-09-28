# A rounded, short full-strength smile

## Owner direction — 2026-09-29

The sticker sheet's **left column, third row** is the reference for `happy=1`:
a short, rounded inverted-U closed eye. The owner approved using this as the
ordinary smile target and keeping the upper-right, tightly squeezed cartoon
expression for a possible later special expression. This is a design direction,
not approval of this newly generated model. Mouth opening stays independent.
Mouth/audio polish remains deferred while facial expressions are evaluated.

Open `expression-study.html?variant=rounded&happy=1&opening=0&angle=0`.
The selector retains the previous shallow arc, its source-normal control, and
the pre-expression model. The three expression sliders and slow cycle also work
with the five mouth shapes and five viewing angles. Zero expression restores
the input face. This is a candidate, not a finished avatar: the skin-color patch
and jagged eye perimeter from [SURFACE_EXPRESSIONS.md](SURFACE_EXPRESSIONS.md)
remain visible and must still be addressed.

## What changed

The full smile uses a stronger curved edge, with rounded stroke ends. It follows
the same fixed source-triangle surfaces; the body, nose and mouth are unchanged.
For normalized horizontal eye coordinate `x/rx` (`rx=.104`), the full-strength
upper reveal edge is `z=.646-.121*(x/rx)^2`. The former edge was
`z=.650-.030*(x/rx)^2`. The black stroke sits just above this reveal edge.

The texture's normalized coordinate range is expanded from ±4 to ±8 so the
stronger U scale does not clamp at the texture edge. A capsule-like distance
field rounds the ink ends. Its main half-span is 2.50 texture-q units and
U scale is 5.5 at full happiness, giving a short stroke with a visibly deeper arc.
The vertical ink band is slightly bolder than the preceding diagnostic.

The first attempt drew a detached black arc above the eye at intermediate
weights. The final candidate separates pink cover and black edge into different
fixed layers. The black layer's static vertex alpha restricts it to the original
eye artwork (including the highlight); it is suppressed over surrounding pink
skin. It shares the upper lid's texture transform. This prevents the large
floating eyebrow observed in the first attempt without altering the head.
Fine antialiasing and edge interpolation are still visible.

Neutral sweep origins move from .87/.37 to .78/.45. All zero-state alpha remains
hidden, but the lids begin affecting the eyes earlier. This remains a standard
continuous VRM weight, not a binary toggle or a viewer-only remap. Visible eye
area is not linear in the weight: the 50% sample starts narrowing the eyes,
while later values close them more strongly. Full blink and relaxed edge
positions are retained; their onset and ink treatment also use the new shared
lid system. Do not claim that those two expressions are pixel-identical to the
previous diagnostic at nonzero weights.

The original source-normal prototype, preceding shallow smile, and mouth models
are preserved as separate artifacts. The builder defaults to its original style;
`EXPRESSION_STYLE=rounded` selects this new output. Skin normals, skin-color
reconstruction, compositing rules and the remaining perimeter limitations are
in [SURFACE_EXPRESSIONS.md](SURFACE_EXPRESSIONS.md).

## Reproduce and evaluate

Prepare the source and control artifacts following [CONNECTED_VOWELS.md](CONNECTED_VOWELS.md)
and [SURFACE_EXPRESSIONS.md](SURFACE_EXPRESSIONS.md), using the same pinned tools.

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run rounded-smile-probe
```

This replaces only `artifacts/rounded-smile` and `-repeat` and writes captures to
`artifacts/rounded-smile-review`. Private images, binaries and audits stay ignored.

The experiment asks whether a stronger full-smile arc can remain short, whether
intermediate ink stays connected to the visible eye, and whether the source face
and mouth survive the new expression system. Evidence is split deliberately:

- [Geometry and bindings](results/rounded-smile-geometry.json): body coordinates
  and mouth bindings are unchanged. The fixed lid/ink offsets are .0004, .0007
  and .0009 model units; maximum parent-plane error is approximately 3.20e-8.
  Reimport resolves six texture binds for each bilateral eye preset and three
  for each unilateral blink. There are no eyelid morphs.
- [Runtime](results/rounded-smile-evaluation.json): candidate and old shallow
  arc have exact zero-eye matches against the input for five vowels at five
  angles (50 comparisons). Four strengths of three expressions at five angles
  in both variants give 120 captures. Mixed-eye weights, a live cycle, reset,
  1280/600/390 px layout and repeat-byte checks are included.
- [Silhouettes](results/rounded-smile-silhouette.json): measure each full-smile
  dark arc's width/height against the preceding arc and count significant dark
  components inside each eye at sampled intermediate weights. This is a fixed
  frontal raster test, not proof for every animation frame or camera angle.
  In the fixed capture, arc widths change from 125/126 px to 120/120 px;
  heights change from 17/17 px to 43/43 px. Each eye has one significant dark
  component at the sampled 25/50/75/100% strengths.

The shared builder’s original mode was regenerated separately and its VRM
remained byte-identical to the preserved shallow-arc artifact.

## Remaining work

Evaluate the rounded full-smile shape and its transition as a whole. Then resolve
the pre-existing pink color/perimeter discontinuity, retaining the head/nose and
mouth-width constraints. The top-right squeezed expression is not implemented
and is not required for the ordinary smile. Mouth onset/audio calibration stays
in the later phase. Target-runtime compatibility, pose/skinning behavior, gaze,
SpringBone and full-pipeline reproduction remain unverified for this candidate.
