# Third selective polygon-reduction trial — 2026-10-12

The owner checked the [second trial](POLYGON_REDUCTION_SECOND_TRIAL.md), reported
no motion problem, and requested another conservative cloud trial. This is a
small additional reduction. Accepted K and both earlier files remain unchanged.

## Result

| Metric | Accepted K | Second trial | Third trial |
| --- | ---: | ---: | ---: |
| Triangles | 201,423 | 133,273 | 132,249 |
| VRM bytes | 20,954,188 | 18,302,056 | 17,855,696 |

The third trial has **34.34% fewer triangles than K**, but only **0.77% fewer
than the second trial**. VRM bytes decrease by 446,360, or 2.44% versus the second
trial. Textures and draw calls remain; no FPS improvement was measured.

- Body: remove 5,414 records referenced by no triangle, saving 411,536 bytes.
  Every drawn triangle-corner attribute and morph value, plus triangle order,
  remains exact. This is storage compaction, not body-surface simplification.
- Ribbon: remove selected low-curvature radial rings, saving 1,024 triangles and
  34,824 bytes. The five parts have 4,736 / 4,034 / 2,522 / 4,738 / 4,028 triangles.
  Retained source attributes, caps, material bands and unit UpperChest weights
  remain exact. The first wing is unchanged from the second trial.
- Mouth, six eyelid meshes and chest repair remain exact to the second trial.
  The rig, VRM expressions, materials, textures and all 13 images are unchanged.

### Stronger sampling corrects the earlier scope

Adding triangle-edge midpoints to both directions of the surface test reveals
an inherited **0.185797 mm** maximum on the unchanged wing. The second trial's
reported `<0.170 mm` used vertices/centroids in the reverse direction, so it
was a result for those discrete samples, not a global surface bound.

Under the stronger, equal sampling, every part's maximum versus K is identical
between the second and third trials. Additional sampled second-to-third change
reaches 0.175355 mm on the left wing. Typical error can still change while the
maximum stays the same. Samples initially above 0.170 mm were rechecked against
all target triangles; neither sampling scheme is a continuous Hausdorff proof.

### Rejected larger reduction

Removing 27,011 exactly zero-alpha eyelid triangles preserved all 192 default
color-renderer images in a probe. However, all 11 forced-shadow comparisons
changed: the host's generated depth material ignored vertex alpha. That probe
was rejected and is not a delivered model. Color invisibility alone does not
establish depth, shadow or outline invisibility across hosts. Final eyelid
geometry is untouched. Further chest/facial reduction also offered little
without relaxing protection or error limits, so those regions were retained.

## Final-byte verification

The VRM hash below was frozen before QA. Toolchain remains Blender 5.1.2,
VRM add-on 4.7.2, three 0.186.1, three-vrm 3.5.5 and Playwright 1.51.1.

- 78 matched standard frames at 1000 × 1000, including 25 face states and
  12 practical poses. All 67 protected eye/upper-face regions match K and the
  second trial exactly; full standard face images match the second trial.
- 129 dense blink/emotion/wink closeups at 900 × 900 are pixel-identical to the
  second trial. Three 3-second, 60 Hz sequences exercise neck, chest, arms and
  blink from front, oblique and profile: 543 state updates and 63 saved motion
  frames. All sampled bone matrices, effective expressions and UV transforms
  match. Motion silhouette masks are exact; the largest motion foreground RGB
  mean difference is 0.005981/255. All 672 dense/motion states are finite, with
  zero runtime errors. There is no spring-bone extension to exercise.
- Twelve final posed dumps preserve drawn body/morph, eyes, mouth, lids and
  chest streams. Zero wing/tail–body crossings in both directions; all five
  bow parts remain closed manifolds without self-crossings. Knot contact is
  intentional: 76 bow-edge / 102 body-edge crossings versus 78/102 previously,
  unchanged 3.5 mm central embedding and no outward contact-bound expansion.
- Actual loader/skinned bounds of the losslessly compacted body match exactly
  in 12 practical poses × 6 morph weights. Final body arrays were reconciled
  with the tested donor. This does not certify every host's culling behavior.
- Editable Blend save/reopen and a separate verify-only process pass. Native
  retained body coordinates, all 13 attribute layers, both shape keys/settings,
  normals and weights are exact; rig, materials and 13 packed images remain.
  Other rebuilt parts match the final VRM. No VRM import/re-export was used.
- Independent review and visual inspection found subtle local ribbon shading
  differences, without new visible tears in the checked frames. The minimum
  standard silhouette IoU versus the second trial is 0.9999985.

These checks do not guarantee arbitrary motions, extreme poses, target-app
imports, host-enforced shadows/outlines or every mixed expression. Existing
upper/rear-side ribbon gaps and native Blend normal-morph representation limits
remain. Ordinary GUI export is not equivalent to the authoritative delivered VRM.

## Private recovery and reproduction

| Item | Library reference | SHA-256 |
| --- | --- | --- |
| Third trial VRM | `libfile_1740697bbc288191b08b378567ba5f4a` | `c3b6fb7bd460242fea23ec6a174741d366710751d0bcc60dd353d795999923a5` |
| Editable Blend | `libfile_fcb575ca15f0819190da17dfdee41330` | `066309f5ddf2cd0b7737b7bbbfc19f3ae2788d37b78c21111e3c6b088d08cbab` |
| Reproduction ZIP | `libfile_107b0c6245a08191a00d2fa821c33dec` | `c8c26ba212921ac22547ab4d7fc00214492745c3c593def6aefa6c2ee2fa1f90` |
| Matched-view comparison | `libfile_f0cbd93cb06c8191abd97438b7146ec6` | `887156d3a4c38443f88e237f54f8e7727dd88c75e4cb6ab4620f30fbb3c0ee19` |

The compact kit contains the selected source-row/index layouts, portable replay
and Blend-build scripts, matched-view comparison, and focused verification.
Models, binary layouts and evidence images remain private and excluded from Git.
Materialize the kit under ignored `artifacts/`, verify its hash, then run:

```sh
python scripts/apply_layouts.py "$MIINEKO_K_VRM" layouts new-output/trial-v3.vrm
```

Only [accepted K](FINAL_2026_10_12.md) and NumPy are needed for byte-exact replay;
no previous trial or transient cloud directory is required. The extracted ZIP
passed CRC/content-hash checks and reproduced the final VRM exactly. The optional
editable Blend build and browser QA are documented in the kit. Blend binary
hashes can differ when saving elsewhere; semantic verification is required.
