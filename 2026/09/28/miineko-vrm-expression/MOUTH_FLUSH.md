# Preserve mouth line weight while reducing its depth step

## Current owner direction

The preceding [feature-depth trial](FEATURE_DEPTH.md) improved the eyes, but the
owner could not see a meaningful W-mouth change. The owner then authorized the
small pink/black joining region to move and explicitly included the vertical
black line below the nose. **Do not narrow the lines:** retain their shape,
location and manga-like weight, and change depth only. The nose itself and the
surrounding head remain fixed.

Open `feature-study.html?variant=mouth-flush&angle=90` and select **口の段差を調整**.
The previous candidate remains **前回：目とw口**. Inspect the front view for line
weight and the side views for depth. This is still a normal-face static candidate,
not an accepted replacement or an animated mouth.

## Construction

`scripts/refine_mouth_depth.py` starts from the verified eyes-only blend, whose
mouth is unmodified. It explicitly triangulates only faces near the mouth, using
their existing tessellation diagonals, then subdivides those edges with five cuts.
The extra vertices lie on the original piecewise-planar surface before adjustment;
this is not a head-smoothing operation. Other faces retain their topology.

The old W/vertical-line artwork is identified through its existing UVs and color.
Those feature vertices are recessed toward the measured local pink surface. The
joining band reaches at most 0.002 model units along mesh edges from the ink, with
a smooth falloff. The upper end of the vertical line eases into the unchanged
nose. The nose guard starts at z=0.495 and protects whole touching triangles.
X/z coordinates, UVs and material assignments are not changed by the depth pass.
The existing textures are retained byte-for-byte. No thinner replacement stroke,
skin-colored cover or new mouth texture is used.

The previous approach (`refine_w_surface.py`, `feature-w-surface`) kept the entire
pink boundary pinned. Subdivision alone increased the movable interior, but the
raised outer rim still dominated the profile. A local skin cover and replacement
stroke were also tried and rejected because they left rings and profile marks.
That cover route is not part of this candidate. Its diagnostic files remain in
ignored `artifacts/w-cover-rejected/`.

## Reproduce

Prepare `feature-eyes/continuous-blink.blend` and VRM using [FEATURE_DEPTH.md](FEATURE_DEPTH.md),
with the same pinned Blender, add-on, Node and comparison Python environment.

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run mouth-flush-probe
```

The task rebuilds the fixed-boundary diagnostic control, the current candidate and
a separate repeat, then runs browser and numeric checks. It overwrites only their
named `artifacts/feature-*` outputs. Source files remain unchanged. All media,
blends, VRMs and detailed coordinate audits remain local and ignored by Git.

## Evidence — 2026-09-28

[results/mouth-flush-evaluation.json](results/mouth-flush-evaluation.json) and
[results/mouth-flush-preservation.json](results/mouth-flush-preservation.json)
record the build and checks:

- 20,637 body vertices after local subdivision, from 8,937. Maximum distance of
  a new point from the original surface before adjustment is 7.83e-8 model units.
- 5,148 vertices change in depth, including 664 in the vertical-line region.
  The 452 changed joining-band vertices are at most 0.001966 model units from ink.
  Maximum recession is 0.016502; median recession is 0.010076 model units.
- Protected coordinates, nose coordinates and all x/z coordinates are identical
  before/after the depth pass. Embedded textures are byte-identical to the source.
- In fixed frontal **unlit source-color** captures, the mouth artwork bounding box
  has the same width/height. Ink count is 4,162 versus 4,142 pixels, with 99.38%
  mask intersection-over-union. The vertical-line crop has identical bounds and
  99.70% mask overlap. Tiny rasterization/occlusion differences remain; this is
  not a claim of identical pixels.
- In the fixed lit side-mouth crop, black area changes from 894 to 415 pixels
  (46.4% of the previous candidate). This is a view-specific visibility measure,
  not a physical volume or a guarantee that every remaining step is gone.
- Outside the mouth crop, maximum lit channel difference is 1/255. The lower nose
  crop has up to 7/255 difference after local subdivision/tangent interpolation,
  although protected nose geometry is unchanged. Do not claim pixel-exact nose
  shading for this topology change.
- Fifteen standard views and 1280/600/390 px layouts pass without page errors.
  Two current-candidate VRMs match byte-for-byte.

The source is `feature-eyes`, SHA-256
`068d4aca5ce4a0e9328beb5533c28dbb03bf578fb91e1cb2ff23d9cdd4a29789`.
The earlier `mouth-aa-aligned` source also remains unchanged. Current candidate
hash and configuration are recorded in the evaluation report rather than duplicated
here.

## Remaining work

Evaluate the stepped-depth reduction and the nose-to-line transition at oblique
and side angles. Small rim irregularities and source shading remain visible.
Keep the original stroke weight in any further adjustments. The 0.002 joining
band is a local permission, not permission to reshape the forehead, cheeks, chin
or nose. Rebuild smile/blink/vowel behavior only after the static structure is
accepted; the old expressions are calibrated for different geometry.
