# Preserve pink head geometry and nose; reduce feature depth

## Later scope update

The owner found the W change insufficient and authorized its joining band and
the vertical line below the nose to move in depth, while explicitly retaining
line weight. [MOUTH_FLUSH.md](MOUTH_FLUSH.md) is the current candidate. The strict
all-pink/stem protection below records the preceding trial, not the new permission.

## Owner correction and initial scope

The owner rejected the broad [thin-face deformation](THIN_FACE.md) because the
side profile changed. Preserving x/z alone did not preserve the head shape.
The current requirement is to keep the pink forehead, cheeks and chin in their
original positions, retain the protruding nose and central connecting stem, and
adjust only the eyes (including highlights) and the lower W mouth.

Open `feature-study.html?variant=eyes-mouth&angle=45`. It compares the previous
normal face, eyes-only adjustment, and eyes plus W adjustment at five angles.
These new candidates are normal-face static studies, not accepted replacements.
The old expression binds are intentionally removed. Smile and animated expressions
must be recalibrated after the normal face is evaluated.

## Method

`build_feature_depth_study.py` starts from the immutable `mouth-aa-aligned` blend.
It reads the source BaseColor image without changing it. UV triangles touching
pink texels protect all their vertices. The chromatic test includes dark pink;
a one-texel dilation conservatively includes filtering/boundary uncertainty.
Only pink triangle components connected to surrounding non-feature skin count
as head skin. Fifteen isolated pink-tinted reflection triangles inside the eyes
belong to the eye features. This avoids leaving spikes where a highlight contains
a small amount of pink color.

An independent spatial guard preserves the nose and stem regardless of color.
Only unprotected vertices within the eye regions or W lobes may move. All x/z
coordinates stay fixed; movement is limited to positive y (recession in Blender).
Surrounding pink vertices fit a local quadratic target. A harmonic surface through
the pinned boundary limits how far the interior can recede, and a graph-distance
taper softens changes near fixed edges. This intentionally leaves some black rim
thickness rather than moving shared pink geometry.

Protected corner normals are retained, as are the original UVs, textures and
materials. No broad skin cover, ellipsoid substitution or redrawn face graphic is
used. Geometry preservation follows the recorded segmentation; it is not proof
that any conceivable definition of a pink pixel is semantically correct.

## Reproduce

Use the earlier blend/VRM, Blender/VRM add-on, Node dependencies and comparison
Python environment from [BASELINE.md](BASELINE.md):

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run feature-depth-probe
```

The task writes `artifacts/feature-eyes`, `feature-eyes-mouth` and separate
`-repeat` directories. Source files remain unchanged. It performs four Blender
builds, browser capture and independent checks of serialized coordinate audits
and screenshot samples. Models, textures, blends, audits and images remain local
and ignored by Git. No dependencies were added or upgraded.

## Evidence — 2026-09-28

[results/feature-depth-evaluation.json](results/feature-depth-evaluation.json)
records both candidates, repeated exports, 15 browser states and three viewport
widths. Both VRMs match their separate repeats byte-for-byte. All four final
Blender runs exit successfully.

[results/feature-preservation.json](results/feature-preservation.json) checks:

- All 8,060 protected vertices are coordinate-identical to the source.
- Every vertex of the 15,121 protected pink triangles is unchanged.
- All 178 vertices in the nose/stem guard are unchanged.
- Original x/z coordinates are identical for the whole mesh.
- In the fixed frontal capture, 378,759 sampled pink pixels outside the eye/W
  artwork have zero channel difference; the nose crop also has zero difference.

The pixel check uses a fixed framing and explicit image regions. It complements
the coordinate checks; it does not certify all viewpoints or every pixel. Side
and oblique views were also inspected. Boundaries, existing baked shading and
black rim thickness remain visible and are still artistic review items.

The source VRM retains SHA-256
`cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31`.
The source blend retains SHA-256
`97d2030f89d53e5081af9fad20cb6511920ad5971a207cc5a6fcc44ff19e9d93`.

## Failed attempts and crash recovery

The first Blender run exported the model but crashed with SIGBUS while saving
the coordinate audit. Triangle RNA handles had been retained across mesh changes
and export, making the later access unsafe. The builder now copies triangle
indices into an owned NumPy array before modifying the mesh and uses that copy
for assertions and audit serialization. The final four builds complete normally;
an exported file alone is not treated as evidence of a successful run.

The first color-only mask also pinned isolated tinted reflections in the eyes,
leaving small peaks after neighboring vertices receded. Connecting the pink mask
to surrounding head skin removed those peaks. A quadratic target alone could
recess the interior too far behind the fixed rim, so the harmonic boundary limit
was added. These changes retain the coordinate-protection constraints.

Next evaluate the normal face and the remaining black rim/shading. If more depth
reduction needs finer boundary topology, preserve the original pink surface while
subdividing the feature boundary rather than broadening the deformable region.
Only then rebuild smile, blink and vowel motion. Gaze, springs and whole-pipeline
reproduction remain outstanding.
