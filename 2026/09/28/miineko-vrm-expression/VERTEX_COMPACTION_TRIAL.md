# Accepted-v7 unused vertex-data compaction

The owner approved cleaning serialized vertex rows that are not drawn, after the
[seventh geometry trial](POLYGON_REDUCTION_SEVENTH_TRIAL.md). This is a separate
storage variant of accepted v7. It does not reduce triangles or rebuild body,
eyelids, ribbon, textures or materials. Production assets and all previous
versions remain unchanged.

| Metric | Accepted v7 | Compacted candidate |
| --- | ---: | ---: |
| Triangles | 87,058 | 87,058 |
| Referenced unique POSITION rows | 51,788 | 51,788 |
| Stored unique POSITION rows | 80,585 | 57,208 |
| Unreferenced stored rows | 28,797 | 5,420 |
| VRM bytes | 17,557,260 | 15,941,856 |

The selected candidate removes **23,377 rows (29.01%)** and **1,615,404 bytes
(9.20%)**. Stored row counts are not a measurement of GPU memory, runtime vertex
invocations, FPS or draw calls. Every ordered drawn triangle-corner attribute and
morph value is preserved exactly after index remapping. Material, image, rig,
expression and non-storage metadata are unchanged.

## Why some unreferenced rows remain

Deleting all 28,797 rows yielded a smaller diagnostic candidate but changed the
native loader boxes and spheres of all six eyelid meshes. Such rows are unused
by triangles, yet Three's skinned bounding-sphere calculation visits POSITION
rows in order and expands its sphere sequentially. Accessor min/max alone does
not preserve this behavior. The naive candidate is not selected.

The selected mapping preserves original relative row order and retains 5,420
unreferenced support rows for the tested bounding boxes, spheres and projected
extents. Accessor extrema are recomputed from the actual stored data rather than
retaining false old min/max metadata. Shared primitive/accessor cohorts, every
attribute/morph stream, skin slots/weights and index ordering use a consistent
mapping. Unsupported storage/reference features fail closed; the script is
pinned to accepted v7 and refuses source/output aliases.

An initial support candidate passed its selection fixtures and matched ordinary
rendering, but an independent 12-pose holdout found fresh all-stored AABB shrink
up to 0.111670 mm in six poses. Cached bounds/spheres, fresh posed spheres,
referenced geometry, rendered sets and transparent order were exact. This was
not demonstrated visual damage, but triggered one bounded conservative revision.
The selected support pool adds 2,048 fixed-seed mixed poses, those twelve now-
selection poses, and complete XYZ/sphere support for the existing 1,404 states.
A separate undisclosed twelve-pose holdout passes with exact fresh/cached
bounds, spheres, rendered mesh sets and transparent order on the revised SHA. No unlimited
holdout/reselection cycle or universal guarantee is inferred.

Support selection is based on explicit finite runtime fixtures. Eyelid stored
rows have multiple bones and varying weights; a rest-position hull or single-bone
argument cannot prove support for every future deformation. Exact triangle-corner
stream identity is distinct from finite bounds/culling/sort parity. No universal
all-pose or all-engine bounds guarantee is claimed.

## Editable source and reproduction

The accepted v7 Blend remains byte-for-byte unchanged. It contains 82,396 stored
editing vertices and 51,411 surface-used vertices. Of 30,985 nonsurface points,
30,979 belong to retained construction edges; deleting them would discard editing
source rather than merely compact the runtime. There are 93,143 loose editing
edges. The six isolated points are also retained in this non-destructive task.

A fresh Blender process reopens and verifies the unchanged editable source. The
private kit provides the deterministic accepted-v7 compactor, retained-row maps
and provenance, and an exact accepted-K-to-final runtime replay. Native-to-runtime
representation differences and post-export corrections remain explicit; ordinary
GUI export equivalence is not claimed.

This variant inherits v7's existing local shading/contact approximations and
v4's host-dependent transparent-lid shadow/depth/outline caveat. Storage cleanup
does not erase those qualifications. Target-application and FPS checks remain
separate from cloud tests.

## Verification and recovery

On the frozen revised SHA, all **678 color-image pairs, 369 eye masks and
76 shadow-mode pairs** match accepted v7 pixel-for-pixel. All 1,404 captured
pose/bone/expression/material/projected-bound state records agree. Actual retained
world-position rows and indexed corner fields match in 51 poses across 1,071
mesh/primitive/pose pairs, with each index stream checked against its own VRM.

Ordinary native-loader lifecycle checks and 57 cached-bound states agree.
Detailed 108-state all-stored bounds and 906-state indexed-vertex observers match
for boxes, spheres, rendered sets, culling and transparent order. The separate
holdout12 is exact on the revised SHA. The observer's shared initial Box3 setup
and stored/indexed distinction remain explicit; these are not universal host or
arbitrary-motion bounds proofs. Identical accepted-v7 baseline records are reused
only with matching hashes, fixtures and runtime conditions; every final candidate
capture/record is newly measured. Clean portable replay measures both models.

The compactor passes 26 synthetic tests and relocated byte-exact runtime/map
reproduction. Fresh-process native reopen and final runtime bridge pass. A
relocated paired six-state render/mask/actual-field smoke also matches. The kit
includes immutable support indices and scripts/seed/fixtures for regeneration;
large raw observation files are represented by hashes and rerun commands.

Independent model review passes within the tested compatibility scope. The
frozen ZIP has 142 entries and 141 manifest hashes; CRC, safe paths, and both
extracted K-to-final and accepted-v7-to-final replays pass independently.

Toolchain: Python 3.12.14, NumPy 2.3.5, Blender 5.1.2 with VRM add-on 4.7.2,
Three 0.186.1, three-vrm 3.5.5, Playwright 1.51.1 and Chromium 134.0.6998.35.
Historical dependencies remain pinned for exact reproduction.

## Frozen identities and private delivery

- Source v7 VRM: `1ddf54c3d5dc79011d1c9dcfa870f023001489a02ee503c2da939cf4171a614d`.
- Compacted VRM: `fe93b33f0d9b4170d4d2bc91fdabe091e1a017709344623ed3383b04a0edf2c9`.
- Unchanged Blend: `4ed3868c2a1beeab66fa36567a24e6c33bbb3b5dada10efa7686b8bc474c70bd`.
- Reproduction ZIP: `f5de5d7bc0f4b7a4c65b70dbba54e298cfaa42202a885f732f3be6eb80fed444`,
  2,057,344 bytes.
- Comparison PNG: `b1eb3a462b19eb3a2a3e0ce410caa333355026aec3bdd60c33d37595eab54794`.

Delivered privately on 2026-10-12 at 15:53 JST:

- Compacted VRM: `libfile_99f76fc424308191915fe084b2f996f6`.
- Reproduction ZIP: `libfile_29c1b63d1e24819192f3deadcdc31cab`.
- Comparison: `libfile_4304c319220c8191804b97de2672eead`.
- Existing editable Blend reattached: `libfile_ef58e3ebbe28819197baa32d21b6e878`.

Owner target-application confirmation is pending for this storage variant.
No geometry binaries or evidence images are published in this repository. Private artifacts retain exact input hashes,
compact reports and executable reproduction instructions.

