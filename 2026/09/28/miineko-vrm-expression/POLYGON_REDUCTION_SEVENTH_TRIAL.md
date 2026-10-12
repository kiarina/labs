# Seventh reduction trial: feature-preserving ribbon reconstruction

After confirming sixth-trial motion in their application, the owner approved a
ribbon-only reconstruction experiment. The quality-priority selection has
**87,058 triangles**, 3,990 fewer than [v6](POLYGON_REDUCTION_SIXTH_TRIAL.md)
(4.38%). Ribbon-only exploratory budgets of 16k and 14k were not forced: the
selected ribbon has **16,068 triangles**. The broader 80k target remains unmet.
K, all prior trials and production assets are preserved.

| Metric | Sixth trial | Seventh trial |
| --- | ---: | ---: |
| Total triangles | 91,048 | 87,058 |
| Five ribbon parts | 20,058 | 16,068 |
| Referenced unique POSITION rows | 53,783 | 51,788 |
| Stored unique POSITION rows | 82,580 | 80,585 |
| VRM bytes | 17,692,908 | 17,557,260 |

Only wing/tail meshes 9, 10, 12 and 13 change. Knot 11, all non-ribbon fields
including unused rows and morphs, rig, expressions, materials and image payloads
remain exact. All ribbon vertices retain unit influence from joint 4; modified
parts have no morph targets. This is not a measured FPS or draw-call improvement.

## Reconstruction and rejected branches

Local area-plane fitting creates new samples and connectivity, projected to the
accepted K surface with explicit v6 source-face/barycentric provenance. Caps,
black trim and material-boundary vertices and faces remain literal v6 geometry.
The final tail fits add source-sheet restrictions, original-orientation checks
and a minimum-angle constraint; separate audits check the selected geometry.
Serialized position/normal/UV
transfer and retained source corners are independently reproduced.

A correct new-vertex transfer does **not** preserve the entire interpolated field.
An 85,448-triangle branch passed structural and sampled position checks but
changed tail-root shading visibly; finite corresponding normal-field angles
reached about 80 degrees. It was rejected for delivery. The selected repair keeps
original tail faces with source vertex-normal pairwise variation above 5 degrees.
That 5-degree value is a preservation-selection rule, not an output error bound.
The former extrema lie on literal retained triangles, preserving their complete
corner fields. Finite same-XY field probes now reach 3.1675 and 2.8628 degrees on
the tails; wings retain maxima of 16.9558 and 18.2917 degrees. These compare
normalized interpolated fields on verified chart domains, with potentially
different Z positions. They are not global angular bounds. UV interpolation and
shading elsewhere also remain approximate.

Earlier smooth ring fits crossed inherited depth-fitting creases and failed.
Coarser adaptive surface samples also missed a new wing maximum. Final independent
checks sample every new triangle on a 1/16 barycentric lattice and exhaustively
re-evaluate extrema and threshold-near points against all target triangles. New
regions pass the declared 0.186 mm finite distance checks against K and v6. A
stronger measured K-relative maximum of 0.195658 mm belongs to unchanged v6
geometry; it is not silently excluded from a claimed global bound. There is no
proven global Hausdorff bound. An inferred ring-angle chart had degenerate or
reversed parameter cells, so it was not used as a one-to-one proof.

## Compatibility and reproduction

The editable companion retains original editing data and adds 960 sampled points:
native stored vertices rise from 81,436 to 82,396 while runtime rows decrease.
Do not equate stored editing vertices with referenced runtime vertices. Native
positions match the final runtime, while preserved native UV/normal storage has
small convention/precision differences. Original shape keys, rig and unrelated
native fields are retained. Inherited post-export corrections mean a normal GUI
export is not promised to reproduce the runtime VRM.

The private reproduction kit provides exact K-to-final runtime replay, the
feature-preserving ribbon fitting/provenance, native rebuild and verification,
and paired runtime diagnostics. Independent fresh-process native reopening and
K-to-final byte-exact replay pass. Blender binary resave identity is not promised.
Models, derived topology payloads and evidence images are not committed here.

This inherits v4's host-dependent transparent-lid shadow/depth/outline tradeoff.
Conservative v3 remains available. The user's successful v6 application test does
not certify this new version or identify the host. Arbitrary motion, every host
and FPS remain untested.

## Final QA and delivery

The established twelve practical poses retain zero wing/tail-to-body crossings
in both directions. A broader 39-pose set already has head/neck-to-wing contact
in v6. No new contact pose, part or body-joint region is observed; the maximum
outward shift of an existing contact-region AABB boundary is 0.551421 mm. This
is not a penetration-depth measurement or a claim of 51 contact-free poses.
Knot and non-ribbon posed arrays are exact. Transverse noncoplanar self-crossing
tests found none; coplanar/tangent touch and edge endpoints are outside that test.

Frozen-SHA standard 78, sweep 192 and body 39 images are hash/camera/pose checked.
The standard face 25 and dense-face 129 images remain pixel-exact to v6. All 672
sweep-state records (including expression samples) and 363 body-state records
match v6 for the captured bone, expression and material-state fields; this does
not assert unchanged ribbon bounds or pixels. Matched shadow diagnostics cover 34 general plus four ribbon views,
each with shadow OFF and host-forced ON. Local shading differences remain;
forced shadow settings are diagnostic, not target-host certification.

The dense blink suite adds 369 color images and 369 visibility masks. All masks
are pixel-exact to v6, with no new eye exposure. The full color frames include
ribbon at the bottom and are not pixel-exact; worst mean RGB difference is
0.043523 on a 0–255 scale. All color differences lie within the projected runtime
ribbon vertex AABB plus two pixels; every pixel outside is exact. This is a
conservative image-region check, not a per-pixel semantic segmentation proof.
It prevents a false claim that every face-oriented frame is identical.

A separate bounds observer renders 906 states at a 64px square viewport and
measures every indexed vertex; detailed 108-state observations include all stored
rows. Both models share one initial `Box3.setFromObject` setup, which may
initialize missing bounds. Subsequent fresh diagnostic boxes do not replace cached
bounds. Sphere/frustum/sort implementations and flags remain unchanged. Non-ribbon
bounds, actual rendered mesh sets and transparent ordering agree, with no nonfinite
values. This is an observer-specific result, not 906-state measurement of every
unused row or universal host certification. High-resolution image QA is separate.

Independent review accepts this as a conditional user trial. The final ZIP
passes CRC, safe/unique paths, all 214 manifest hashes and extracted K-to-final
byte-exact replay (215 entries). The package excludes raw model assets, bulk
captures and 215 MB of raw observer records; compact summaries, raw-record hashes
and rerun scripts preserve the tested scope. Native contract tests pass 12 cases;
ribbon sampling tests pass five. A relocated paired motion6 smoke and the dense
color-localization replay also pass.

| Delivered item | SHA-256 | Library recovery ID |
| --- | --- | --- |
| VRM, 17,557,260 bytes | `1ddf54c3d5dc79011d1c9dcfa870f023001489a02ee503c2da939cf4171a614d` | `libfile_3b12fc7d28688191bed6e49cb6c71049` |
| Editable Blend, 15,786,232 bytes | `4ed3868c2a1beeab66fa36567a24e6c33bbb3b5dada10efa7686b8bc474c70bd` | `libfile_ef58e3ebbe28819197baa32d21b6e878` |
| Reproduction ZIP, 2,859,761 bytes | `7af57290eb622c19f612467d0ae7bcccca70595b491492b591d81a4b615dd336` | `libfile_cf72247401d08191b368a2fb03056ae7` |
| Comparison PNG, 766,401 bytes | `595601d587b110eb4e03390c6371c171bd9dfbdee04ce152ce4e756114bdaf5b` | `libfile_9b618c1b4bb48191bc69e957bb227420` |

Recover matching v6 inputs through the [sixth-trial record](POLYGON_REDUCTION_SIXTH_TRIAL.md)
and K through [the production record](FINAL_2026_10_12.md). Verify hashes before
following the private ZIP's `runtime/`, `native/`, `ribbon/` and `qa/` commands.
Pinned tools are Python 3.12.14, NumPy 2.3.5, SciPy 1.17.0, Blender 5.1.2,
VRM add-on 4.7.2, Three 0.186.1, three-vrm 3.5.5, Playwright 1.51.1 and Chromium
134.0.6998.35. No model/component arrays, textures or diagnostic images are public.
