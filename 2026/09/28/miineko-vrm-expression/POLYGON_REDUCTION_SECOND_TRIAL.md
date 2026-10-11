# Second selective polygon-reduction trial — 2026-10-12

After reviewing the [first trial](POLYGON_REDUCTION_TRIAL.md) without major
visible breakage, the owner requested further reduction. This second file is
another comparison candidate. Accepted K and the first trial remain unchanged;
no automatic replacement of the finished assets is implied.

## Result and selection

| Metric | Accepted K | First trial | Second trial |
| --- | ---: | ---: | ---: |
| Triangles | 201,423 | 154,786 | 133,273 |
| VRM bytes | 20,954,188 | 19,081,128 | 18,302,056 |

The second trial has **33.83% fewer triangles than K**, and **13.90% fewer than
the first trial**. VRM bytes are 12.66% below K. Textures and draw calls remain;
this is not a measured FPS result.

Three source-vertex layout changes account for the result:

- Mouth: 8,214 triangles. Adaptive triangulation keeps all 648 original boundary
  vertices and all 3,168 fade-region triangles. Float64 triangle-overlay maximum
  depth difference from K is 0.138686 mm; dense-sample p99/mean are
  0.035132/0.005290 mm. Color/alpha samples are exact; maximum interpolated normal
  difference is 0.155915°. A denser 50 µm selection threshold was chosen over the
  smaller 75–150 µm probes to reduce typical error.
- Ribbon: 21,082 triangles across five parts. Angular density varies per ring,
  while all 35 rings, caps, material bands and retained attributes remain.
  Sampled bidirectional surface difference from K is below 0.170 mm.
- Chest repair: 12,411 triangles. Selectively reverse the last midpoint
  refinement, preserving every seam edge/attribute, local repair, a 10 mm seam
  collar, restored cage and the whole knot-contact neighborhood. The final
  piecewise-linear overlay correspondence bound is 0.049949 mm across the
  12 tested poses. Retained weights are exact; removed-midpoint weight-component
  interpolation differences are at most 0.000870616.

The main body, ears, eyes, six eyelid meshes, morph arrays, rig, expression
bindings, materials, textures and 13 image payloads remain exact. Chest
interpolation is not mathematically unchanged everywhere: measured additional
pose-dependent deviation, after subtracting rigid chest motion, reaches
0.054659 mm; total posed correspondence stays within the bound above. Those
vectors need not align. Do not extrapolate the sampled bounds to arbitrary poses.

A midpoint-only chest check initially missed larger transition-diagonal errors.
Those neighborhoods were retained, and a full triangle-overlay check replaced
the weaker midpoint criterion. The complete mounting neighborhood was retained
rather than protecting only the central ray hit.

## Verification tied to the delivered bytes

The final saved VRM hash below was frozen before runtime QA. Use the same
Blender 5.1.2 / VRM add-on 4.7.2 and cloud runtime versions as the first trial:
three 0.186.1, three-vrm 3.5.5, Playwright 1.51.1, matched 1000 × 1000 frames.

- 78 frames, zero runtime errors; all 67 protected eye/upper-face regions were
  pixel-identical to both K and the first trial. Protected geometry was exact in
  all 12 actual runtime pose dumps. Three-way images were visually inspected.
- Twelve static practical poses: zero bidirectional wing/tail versus complete
  body crossings, zero ribbon-part self-crossings and zero chest self/body
  crossings. Final rendered chest/body arrays exactly matched the tested arrays.
- Knot contact stays intentional: bow-edge crossings are 270/150/78 for
  K/first/second, with 102 skin-edge crossings throughout. Center embedding is
  3.5 mm in every pose. The largest outward contact-bound shift from K is
  0.004291 mm, in the same chest mounting region.
- The editable Blend was saved, reopened, then independently reopened in
  verify-only mode. Protected meshes, object settings, rig, material graphs and
  13 packed images remained exact; rebuilt meshes matched the final VRM.

Existing upper/rear-side ribbon gaps and native Blend normal-morph limits
remain. Static pose checks are not continuous-motion, extreme-pose, spring,
tangency/coplanar-contact or target-app certification. Owner visual review is
still required to adopt this second candidate.

## Private recovery

| Item | Library reference | SHA-256 |
| --- | --- | --- |
| Second trial VRM | `libfile_143e3c46189c819188916656d13a85bc` | `1183694cba6db6a9efd3a1e73307991f127a8d9f2189d55ad46b98be558b4943` |
| Editable Blend | `libfile_6b3238a80818819198cd2b90897f98b1` | `119690802effd9cace777a3f78231a4b0a5fc53b54c87398f8cd13b5f57f95a1` |
| Reproduction ZIP | `libfile_ba6ab6409fe88191ab6ee43fdbd2fb66` | `4686494fd781c7f59aab00c25504fe5f28f6dff7a240e6fa2d15cb37104b8e67` |
| Three-way comparison | `libfile_50f5271419dc8191858a02a84dc31e55` | `10265038961569f3ba66a773864311e91cb76172172cf5958d1174a73f9a0e43` |

The compact kit contains exact selected layouts, scripts, focused validation
and the three-way comparison. Large binaries and model-derived data remain
private and excluded from Git. Materialize it under ignored `artifacts/` and
verify its hash. From the extracted kit, with Python 3 and NumPy:

```sh
python scripts/apply_layouts.py "$MIINEKO_K_VRM" layouts new-output/trial-v2.vrm
```

Only [accepted K](FINAL_2026_10_12.md) is required as the model input; the first
trial and transient cloud folders are unnecessary. The extracted ZIP passed
CRC/content-hash checks and reproduced the final VRM byte-for-byte. Selection
used Python 3.12.14, NumPy 2.3.5 and SciPy 1.17.0; exact layout replay needs only
NumPy. This is a selected-layout recipe, not an arbitrary-model simplifier.
The optional Blend build and its semantic verification are documented in the
kit; binary Blend hashes can vary after saving to another path.
