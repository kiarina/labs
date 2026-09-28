# An AA opening connected to the source W contour

## Direction and scope

The owner found the revised mouth depth improved and suggested joining the W
line to the lower contour of an open mouth. The provided sticker sheet guides
the red interior and bold, simple outline; it remains a reference rather than an
exact-match target. This first probe keeps the W as the upper contour and adds a
rounded lower contour that meets it on both sides.

Open `mouth-study.html?variant=connected&angle=0&opening=1`. The opening slider,
**ゆっくり開閉**, **閉じる**, and five camera directions are available. Zero restores
the source normal face. The selector also shows the source directly.

The new `mouth-connected-aa` VRM has **AA only**. Other vowels, blinking,
relaxation, emotions and speech playback have not been restored to this geometry.
The previous motion viewer remains available through the page link. On 2026-09-29,
the owner approved this direction as closer to the sticker sheet. Keep this AA
artifact as a comparison reference. The next [five-vowel probe](CONNECTED_VOWELS.md)
extends the method; its new vowel shapes have not yet received artistic approval.

## Reproduce

Prepare `feature-mouth-flush` according to [MOUTH_FLUSH.md](MOUTH_FLUSH.md), using
the same Blender/VRM add-on, Node dependencies and comparison Python environment:

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run connected-aa-probe
```

This builds `artifacts/mouth-connected-aa` and a separate `-repeat`, checks the
surface and imported binding, runs browser captures, then measures the visible
corner connections. Existing files in those two output directories are replaced.
The source model is hash-checked and remains unchanged. Character assets, blends,
VRMs, generated palette, captures and detailed audits stay local and ignored by Git.

## Construction

The source W, nose, eyes and body mesh are not deformed. The added opening is
clipped from the actual source triangles in narrow x strips, then offset by
0.0007 model units toward the front. This avoids interpolation of a separately
sampled depth grid across the detailed head surface. The added vertices are
weighted to the head bone.

A standard VRM texture-transform bind reveals a procedural red/black palette on
this **fixed** surface. The moving reveal edge supplies the lower black contour;
the visible source W supplies the upper contour. The edge is a rounded U with no
central lower-lip peak. Its nominal central stroke thickness is .010 model units.
The source line is not thinned or replaced, and its ink suppresses the new layer
through vertex alpha. This is a cartoon surface opening, not an anatomical cavity.

In Blender coordinates, the reveal boundary is:

`z = .479 - .089 * AA + .078 * (x / .074)^2`

The material UV shift is .267 at AA=1. Standard glTF unlit material and vertex
RGBA are used. The mouth texture uses LINEAR filtering without mipmaps to prevent
neutral-alpha bleed. No custom viewer shader or JavaScript geometry deformation
is needed.

The exporter places a dummy white attribute in `COLOR_0` and the intended mask
in `COLOR_1` for this node layout. The builder explicitly assigns the mask accessor
to standard `COLOR_0` on the mouth primitive. Without this correction, the red
layer can overpaint the original W. Source body primitives are not changed.

## Observations — 2026-09-29

- [results/connected-aa-evaluation.json](results/connected-aa-evaluation.json):
  45 opening/angle states, five exact closed-framebuffer matches against the
  source, a complete slow open/close cycle, and layouts at 1280/600/390 px pass.
  The two generated VRMs are byte-identical.
- [results/connected-aa-contact.json](results/connected-aa-contact.json): the
  frontal image is split into left and right halves. All sampled new lower-rim
  pixels connect to the original W within their own half. The eye/nose image
  region is unchanged. This is a raster connectivity check, not a continuous
  geometric or all-view proof.
- [results/connected-aa-geometry.json](results/connected-aa-geometry.json):
  20,070 added vertices and 33,636 triangles. After reversing the fixed offset,
  maximum error from the owning source triangle's plane is about 1.99e-8 model
  units. Maximum vertex distance to the source surface is 0.000700002 model units.
  This establishes close surface following, not collision freedom in every pose.
  Blender reimport resolves one AA texture bind and no AA morph bind.

The first uniform-grid attempt had sampled depth errors of roughly 3.5 mm behind
and 4.5 mm ahead of the face when one model unit is one meter, despite fitting its
vertices. It was replaced by source-triangle clipping. Y-ray differences near
steep source edges were also unsuitable as the sole clearance metric, so the
final audit checks parent planes and nearest Euclidean surface distances.
Sampling source UVs by re-casting at newly clipped vertices also hit a numerically
degenerate triangle and produced NaN. The final clipper carries the parent
triangle UV coordinates through clipping instead of re-sampling those vertices.

Opening weight is not proportional to visible red area. In the current frontal
samples, weights 0 and .1 show no red; .25 shows 4 red pixels, .5 shows 348 and 1
shows 3,710. The thick source line hides the smallest openings. Calibrate driving
timing/strength before reusing the previous speech preview with this method.

The source `feature-mouth-flush` hash remains
`989f33cb81f91a99e2112fb9ce7df47e2734096d649519950f371cdddbc99665`.
Current output hash is recorded in the evaluation report.

## Next work

The owner approved the opening direction. Continue with [CONNECTED_VOWELS.md](CONNECTED_VOWELS.md)
for onset response and the other vowels.
The W remains fixed in this first probe; adapting its curvature during opening
is a separate possible refinement. Preserve the accepted closed face and original
line weight. Then derive the other vowels and retest mixtures before reconnecting
audio. Eye expressions, gaze, springs and whole-pipeline reproduction remain open.
