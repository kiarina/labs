# Conservative polygon-reduction trial — 2026-10-12

A separate cloud-built trial of the [accepted K delivery](FINAL_2026_10_12.md),
requested to investigate lighter geometry while preserving appearance and rig
behavior. The trial was delivered for comparison; it is **not accepted as a
replacement for K**. The finished private assets and K recovery records remain
unchanged. No models, textures, screenshots or model-derived arrays are added
to this public repository.

## Question, method and result

Can selected dense, rigidly skinned surfaces be retessellated without changing
protected face/body data or expression bindings? Compare the final saved VRM
against K with identical cloud-runtime cameras, lights and poses, then verify
decoded data, topology, contacts and the matching editable Blend.

| Metric | Accepted K | Reduced trial |
| --- | ---: | ---: |
| Triangles | 201,423 | 154,786 |
| VRM bytes | 20,954,188 | 19,081,128 |
| Runtime vertices, counting shared accessor blocks once per mesh | 121,400 | 97,973 |

This is a **23.15% triangle reduction** and **8.94% file-size reduction**.
Runtime seam splits make these vertex counts differ from Blender's editable
vertex count. Textures and draw calls are retained; FPS was not measured.

Only the mouth and five ribbon parts change:

- Mouth: 49,896 → 14,949 triangles. Keep the narrow RGB/alpha fade and contour
  rows 118–126 fully sampled; reduce the smoother interior of its 199 × 127 grid.
- Ribbon: 44,800 → 33,110 triangles. Curvature-aware angular thinning retains
  all 35 rings, original cap centers and material bands.
- Retained vertex attributes are copied exactly. The body, ears, eyes, six
  eyelid meshes, chest repair, morph arrays, rig, expression definitions,
  materials, textures and image payloads remain unchanged. These changed
  components have uniform rigid head/chest weights, also preserved exactly.
- Edit GLB arrays directly and compact unused data. Do not substitute a plain
  Blender VRM export for this post-export-preserving pipeline.

Rejected probes matter: uniform 2× mouth reduction distorted its narrow color
and alpha transition (maximum sampled component errors 0.627/0.746); blanket
50% ribbon thinning produced local sampled surface differences up to 1.30 mm.
The delivered selective version avoids those choices.

## Final-artifact checks and boundaries

All runtime evidence is tied to the final VRM hash below. The Linux cloud
runtime used three 0.186.1, three-vrm 3.5.5, Playwright 1.51.1 and matched
1000 × 1000 frames. Blender 5.1.2 with VRM add-on 4.7.2 saved, reopened and
independently rechecked the editable file.

- 78 matched frames, zero runtime errors; 67 protected eye/upper-face regions
  across 25 expression/blink conditions were pixel-identical to K.
- Twelve static practical poses: zero detected wing/tail versus complete-body
  edge/triangle crossings in both directions; all five ribbon parts had zero
  detected self-crossings and remained closed, outward two-manifolds.
- Knot contact is intentional: baseline/candidate bow-edge crossing counts
  were 270/150, with 102 skin-edge crossings in both. Contact stayed within
  baseline bounds; center embedding stayed 3.5 mm in every sampled pose.
- Mouth sampled depth error: maximum 0.271 mm, p99 0.055 mm over 150,337 samples;
  sampled color/alpha interpolation difference zero, UV error ≤1.2e-7,
  interpolated normal difference ≤0.287°. Minimum sampled body clearance was
  unchanged. Ribbon sampled bidirectional surface error was below 0.172 mm.
- The packed Blend retained protected meshes, object settings, rig, material
  graphs and all 13 packed images. Rebuilt positions matched the VRM within
  1.2e-8; weights and the mouth's named color layer matched exactly.

These are sampled static checks, not continuous-motion certification or a
performance benchmark. Tangency/coplanar overlap, extreme poses, intermediate
motion and target-app compatibility remain unverified. K's existing upper and
rear-side ribbon gaps remain. The inherited native Blend morph-normal limits
still apply. Small measured differences are not proof of identical appearance;
owner review of the comparison remains the adoption gate.

## Private delivery and reproduction

| Item | Library reference | SHA-256 |
| --- | --- | --- |
| Trial VRM | `libfile_cf8c5bfa251881918967500085fd54f5` | `91905df9eb2ad4272b53a90f62ca96d0f76df4f2ee6e311c61c2a39ec1479f39` |
| Editable Blend | `libfile_79702db3ace08191b5533cec9d5897e1` | `210ffd8029e37dcf5c0a79959c322e8cd12725c62a9899fcaea58c2c2fd590eb` |
| Reproduction ZIP | `libfile_74c24631abec8191842620344b1feb6b` | `fa9062f82b58ff47137dcc7b5199e1e90f65fbfe7fc97bf266e4250298248577` |
| Before/after image | `libfile_121f1d13c75c819183d8b890f74e1070` | `4808e16cd7032d5fe97b790a795a6a537548cfa66a48b34d89ff314971e9dce9` |

Materialize the private kit and accepted K source through Library, checking the
hashes recorded here and in [FINAL_2026_10_12.md](FINAL_2026_10_12.md). Keep them
under the already ignored `artifacts/` directory. Unlike K's own RC2-based
recipe, this reduction recipe takes accepted K directly. In the extracted kit,
with Python 3 and NumPy:

```sh
python reproduce.py --source-vrm "$MIINEKO_K_VRM" --out-dir new-output
```

The kit contains reduction/build scripts, pose definitions, quantitative
validation and the comparison image, without embedding the source model.
Its CRC was checked; a fresh extraction reproduced the trial VRM byte-for-byte.
Follow the kit's README for the optional Blend build and runtime dependencies;
Blend hashes can change with output paths, so retain semantic verification.
Do not publish the private kit or import large trial outputs into Git.
