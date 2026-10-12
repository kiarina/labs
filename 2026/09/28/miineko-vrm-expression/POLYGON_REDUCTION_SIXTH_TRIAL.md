# Sixth reduction trial: sampled lid patch reconstruction

After reporting that motion in the [fifth trial](POLYGON_REDUCTION_FIFTH_TRIAL.md)
worked in their application, the owner approved a cloud prototype rebuilding lid
patches and transferring their fields. This does not identify or certify that
application for the new result. The selected candidate is **91,048 triangles**,
3,722 fewer than v5 (3.93%). The exploratory 80k target remains unmet. K and all
previous trials remain available; production assets are unchanged.

| Metric | Fifth trial | Sixth trial |
| --- | ---: | ---: |
| Triangles | 94,770 | 91,048 |
| Six lid triangles | 21,141 | 17,419 |
| Referenced unique POSITION rows | 56,901 | 53,783 |
| Stored unique POSITION rows | 81,371 | 82,580 |
| VRM bytes | 17,630,744 | 17,692,908 |

Only the six lid meshes change. Original stored rows are retained as exact
prefixes; 1,209 sampled rows are appended. Thus triangle and referenced-row counts
fall while file bytes and stored-row counts rise. This is not a measured FPS,
memory or draw-call improvement. Image payloads and resolution are unchanged.

## Method, transfer and independent checks

A larger two-vertex cavity is retessellated around a newly placed point. Each new
field is reconstructed from explicit source-triangle/corner barycentric provenance
plus a bounded fitting delta. Position, normal, both UV channels where present,
encoded color/alpha and joint-ID-aligned weights are verified from the actual
serialized arrays. The modified lids have no morph targets; untouched body morphs,
rig, expressions, material/image data and all other mesh fields remain exact.

Literal source triples and source-corner data are retained on surviving faces.
Boundaries, attribute discontinuities, projected overlapping sheets, runtime-mapped
profile patches and native custom-normal split groups are protected. Right-side
triangles with five source joints are locked; new rows never truncate influence
support or introduce positive weight outside their source support. There are no
new repeated-index or zero-area triangles.

The first seven-probe fit missed continuous field extrema and produced a grazing
profile eye-edge sample. It was rejected. The selected method checks vertices of
all source/candidate intersection cells and restores the affected runtime patch.
Affine fields use cell extrema; normalized normals use finite samples, not a
proven global angular bound. Maximum incremental v5-relative rest depth is
0.047999 mm, inward depth 0.019210 mm, UV0 component 4.81626e-6, alpha 0.000485405,
joint-weight component 0.000249662 and sampled normal chord 0.00339022.

These limits are incremental to v5. Cumulative measured rest depth versus v4 is
0.076512 mm and exceeds historical budgets on some cells. Do not describe v6 as
meeting the old v4/K error limits. Actual-loader position comparisons are a
separate finite measurement: 57 actual-loader states reach 0.0881573 mm at the
right lower lid, with retained corners exact. There is no invented posed-position gate or claim
that posed normals are numerically invariant.

A terminal lower-lid search over extra edge placements and a proper weight-simplex
projection offered only 36 potential faces before runtime/native QA. That branch
was not adopted. Very-low-alpha interior patches are scarce; color/alpha limits
were not relaxed to hit a target. This is a bounded search result, not proof that
further topology optimization is impossible.

## Compatibility and reproduction

This inherits v4's explicitly accepted host-dependent shadow/depth/outline risk
from removing fully transparent lid faces. It is not a universal replacement for
conservative v3. Additional interpolation differences are measured against v5;
that comparison does not erase inherited approximations or existing ribbon gaps.
Arbitrary motion, every target application and FPS remain untested.

The editable companion transfers native source-corner fields using their native
coordinates, UV conventions and split normals. It retains the original editing
arrays, shape keys and rig. Inherited native-versus-post-export-runtime differences
remain explicit: a normal GUI export does not reproduce the final runtime VRM.
The private kit provides byte-exact runtime reconstruction from accepted K, with
source-row/index instructions and explicit new field rows. It also rebuilds and
verifies native arrays from the matching v5 Blend/VRM and final runtime. Byte-exact
Blend regeneration is not promised. Derived geometry is included only in the
private kit; no models, textures or evidence images are committed here.

## Final QA and recovery

The frozen final SHA has 678 ordinary native-color captures: 78 standard,
192 dense-face/motion, 369 extra blink views (nine directions × 41 levels) and
39 body views. Shadow testing adds 68 candidate images in 34 OFF/34 forced-ON
paired conditions, for 746 primary native images. The supplementary 51-view pilot
and six head/neck views overlap parts of that coverage. The sweep harness records
672 states; the body harness records another 363. No runtime errors or non-finite
states occur. This is sampled playback, not all-motion certification.

All 369 blink visibility masks were independently compared. At symmetric threshold
32, 285 frames contain 965 newly visible pixels in total, at most 16 per frame.
Every new pixel lies within one pixel of the prior visible region; no new visible
pixel is more than two pixels from prior visibility. Native-color review of worst
cases finds no new isolated internal hole. The mask includes pink eye-material
texels, so flags are diagnostics rather than automatic hole verdicts. Maximum
mean RGB difference is 0.004249/255, while the largest single-channel difference
is 136/255 at a localized outline sample. Small means do not imply identical pixels.

The 22 fullbody and 12 practical standard images are exact to v5. Other views have
small edge/shading differences; minimum thresholded silhouette IoU is 0.9999961.
All 108 inspected cached/fresh bounds and transparent-sort states are exact. Bow
and adjacent-skin contact neighborhoods remain exact in 12 practical and 39 body
poses; this preserves inherited attachment embedding rather than claiming zero
penetration. In shadow comparisons, 12/34 OFF and 2/34 forced-ON pairs are exact;
maximum mean RGB difference is 0.003002/255 OFF and 0.005940/255 ON, with maximum
channel differences 79 and 86. These are finite diagnostic lighting conditions.

Independent review reproduces the six transferred field sets, rest position/alpha
overlays, original-K runtime replay and fresh-process native reopen. The portable
component package passes 16 regressions, all six exact finalizer replays and a
fresh mesh-2 optimizer regeneration. Native tests pass 20 cases. Relocated paired
QA smoke reproduces 12 native/mask pairs and six posed field streams. The final
ZIP independently passes CRC, 169 manifest hashes and extracted K-to-final replay.
It contains 170 entries, with no raw model assets or incomplete live reports.

| Delivered item | SHA-256 | Library recovery ID |
| --- | --- | --- |
| VRM, 17,692,908 bytes | `67a37b26f6e113a594290ae6cdf8febb7e2f20b81b80783ef4c9b4479953839c` | `libfile_88939fd28f308191a6d636f59653123b` |
| Editable Blend, 15,956,882 bytes | `7b33b97e9ed193ba4204108ddef28beab9b4d39850219be7d96bbc7e42455832` | `libfile_a06c52bdc0208191b2d057b4be56c42d` |
| Reproduction ZIP, 2,647,626 bytes | `bd5180235032afe0e917b6eea75327a4c50e494070ad1223ba00927cb84d85ea` | `libfile_6f4f962d44a0819185d9c67cfeba23d8` |
| Comparison PNG, 726,017 bytes | `37d2887719f18c2d013866dfb3a6b8446dba3721a2a3381a61d02588c40c4758` | `libfile_9d758b26e5fc8191aa2c14724cae670c` |

Recover matching v5 inputs through the [fifth-trial record](POLYGON_REDUCTION_FIFTH_TRIAL.md)
and accepted K through [the production record](FINAL_2026_10_12.md). Verify hashes
before following the private ZIP's `runtime/`, `native/`, `lids/` and `qa/` commands.
Pinned tools remain Python 3.12.14, NumPy 2.3.5, SciPy 1.17.0, Blender 5.1.2,
VRM add-on 4.7.2, Three 0.186.1, three-vrm 3.5.5, Playwright 1.51.1 and Chromium
134.0.6998.35. Model/component arrays, textures and diagnostic images stay private.
