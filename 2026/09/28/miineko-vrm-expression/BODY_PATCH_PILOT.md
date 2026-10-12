# Body-patch reconstruction pilot: no candidate selected

The owner confirmed the [v7 vertex-data cleanup](VERTEX_COMPACTION_TRIAL.md)
worked in their application on 2026-10-12 at 20:09 JST and authorized a small
body reconstruction trial. Three newly supplied private inputs restored the
accepted compact baseline byte-for-byte. This pilot does not replace accepted
v7 or K, and does not produce a new accepted VRM/Blend.

## Question and frozen scope

Can a small, smooth rear-body patch use fewer triangles while preserving its
perimeter, shading, texture interpolation and mixed-joint deformation? The
starting compact runtime has 87,058 triangles, of which body primitive 0 has
31,837. It stores 57,208 POSITION rows, references 51,788, and occupies
15,941,856 bytes. The exploratory 80k whole-model target would require another
7,058 triangles; that target is not a quality gate or a promised result.

The pilot protects face/mouth/eyes/ears, morph-active areas, seams, joint/contact
neighborhoods and silhouette-sensitive regions. Existing stored rows and their
relative order, including the compact variant's 5,420 undrawn support rows, are
retained. Changing a surface still requires fresh loader/bounds checks: preserving
old rows alone cannot prove identical bounds after appending new skinned rows.

## New incremental contract

These are explicitly new conservative pilot criteria, established before
candidate selection, rather than reconstructed historical v5 tolerances:

- Rest displacement at most 0.025 mm; tested posed displacement at most 0.05 mm.
- Normal-field, geometric-normal, tangent and bitangent differences at most 1°.
- UV component difference at most 2.5e-6 and texture-space distance at most
  0.01 texel using the actual 4096 × 4096 texture dimensions.
- Joint-aligned weight component difference at most 1e-4; no truncated influence
  support or new positive joint outside the donor source triangle.
- Literal boundary/source-corner preservation and zero morph POSITION/NORMAL
  fields throughout the selected cavity; no new degenerate, flipped or
  overlapping chart triangles.

New rows use explicit donor face/barycentric provenance, float32 serialization,
normalized transferred normals and no fitting delta. Correct transferred rows
are not a substitute for checking interpolated fields. Affine-field extrema use
source/candidate intersection-cell vertices in a local geometric chart; angular
fields use explicitly finite probes. Skin weight-times-position/morph products
and actual posed fields are separate observations.

## Bounded search and result

A two-vertex cavity is rebuilt around one sampled replacement point, retaining
its perimeter. Three rear-body regions, 49 cavity edges and three fixed edge
placements (0.25, 0.5, 0.75) give 147 attempts. No passing candidate is selected.
Of the 147 placements, 123 fail manifold/boundary checks, nine fail attribute-
split checks and three exceed four-joint support. The twelve remaining measured
placements all exceed the frozen quality limits. The three selected regions
contain 91 distinct fully interior source triangles.
One best combined-metric example has rest error 0.726679 mm, geometric-normal
error 7.080264°, aligned weight error 0.0111099 and texture shift 0.437771 texel.
These are already sufficient to reject it; unrun rendering is not the reason
for numerical rejection. The accepted runtime therefore remains unchanged.

The first same-UV correspondence check could not establish independent UV-field
preservation. It was replaced by local geometric-chart comparison; the earlier
result and an implementation chart-unit bug are retained as diagnostic history.
No tolerance was loosened to improve the count.

This is a negative result for a bounded cavity method, not proof that all body
retopology is impossible. Larger patch layouts with multiple fitted vertices and
joint-aware optimization are different experiments whose quality and savings
have not been established. A low triangle count alone would not justify them.

## Verification scope and environment

The supplied ribbon-v7 VRM and unchanged editable Blend match their recorded
hashes; all 141 archived compaction-kit hashes pass. Running that kit reproduces
compact SHA `fe93b33f0d9b4170d4d2bc91fdabe091e1a017709344623ed3383b04a0edf2c9`.
Pinned Blender 5.1.2 and VRM add-on 4.7.2 are restored for read-only native
inspection. The original native body retains Basis and Surprise Ears Up,
construction geometry and inherited native/runtime rounding differences.

The available Chromium 134 binary could not launch because the executor denied
socket creation, including through the supported escalation route. Browser
image, shadow, native-first-render and transparent-sort checks are explicitly
unrun. Supplemental Node Three/three-vrm CPU loading exports 12 practical and
39 body posed-geometry captures from the fixed body sweep. Dummy image metadata
is used only for CPU loading; this is not visual or renderer certification.

An independent implementation rebuilt the triangle-intersection cells and
recomputed rest, UV, texture-space, joint-weight and geometric-normal extrema
for all twelve measured placements, agreeing within 1e-8. It also found no
same-mesh chart interior overlap in those twelve cases. This independently
supports the bounded rejection, not a global impossibility claim.

Across the 51 CPU-loaded practical/body poses, the example above reaches
0.799589 mm displacement at chest-right15, exceeding the frozen 0.05 mm gate.
The source LBS reconstruction matches exported vertex positions after matching
GLTFLoader's float32 skin-weight normalization. Omitting that normalization was
a rejected implementation assumption and is recorded in the private reports.
Read-only native reopen and source-corner mapping checks pass. No new native
companion, final renderer check or edited model is claimed.

The private source-only diagnostic kit retains fixed regions/placements, gates,
rejection reasons and rerun instructions against the verified compact input.
No failed geometry, model binaries or evidence images are published here.

Production assets, textures, triangle counts, vertex counts and delivered model
bytes remain unchanged. FPS, arbitrary poses and all-host compatibility are not
newly measured. Existing accepted-v7 shadow/contact qualifications still apply.
