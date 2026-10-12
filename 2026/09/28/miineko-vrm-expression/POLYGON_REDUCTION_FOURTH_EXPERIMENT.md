# Fourth reduction experiment: shadow-sensitive zero-alpha pruning

After the [third trial](POLYGON_REDUCTION_THIRD_TRIAL.md), the owner explicitly
requested the larger reduction experiment despite the disclosed shadow risk.
This is a separate conditional experiment, not a replacement for the conservative
third trial or accepted K. All earlier files remain available.

## Result and exact change

| Metric | Accepted K | Third trial | Fourth experiment |
| --- | ---: | ---: | ---: |
| Triangles | 201,423 | 132,249 | 105,238 |
| VRM bytes | 20,954,188 | 17,855,696 | 17,693,552 |

Removing 27,011 faces gives **20.42% fewer triangles than the third trial**, or
**47.75% fewer than K**. File size falls only **0.91% versus the third trial**:
vertices, images and draw calls remain. FPS was not measured.

Only index arrays of the six eyelid meshes change. A face is eligible only if
all three source `COLOR_0` alpha values are exactly zero. Every nonzero-alpha
triangle remains, in original order. All stored vertex attributes, skin weights,
morphs, accessor bounds, materials, expressions, textures and other mesh indices
are exact to the third trial. Keeping unused vertices deliberately preserves
position bounds and sorting inputs rather than chasing additional byte savings.
The six lid meshes go from 57,378 to 30,367 triangles.

No further mouth, chest, body or ribbon approximation is introduced. The third
trial's inherited approximations, stronger sampling caveat and existing
upper/rear-side ribbon gaps still apply.

## Why this is conditional

The six materials use `BLEND` with vertex color alpha. The source has no lid
morphs or material-color bindings; all 36 lid expression bindings change texture
coordinates. Under the tested alpha-aware color pass, interpolation and UV
changes cannot turn three zero-alpha corners into a visible contribution.
The pinned loader sets `depthWrite=false` for these materials.

That reasoning does **not** establish universal invisibility. Host-generated
shadow/depth passes may ignore vertex alpha, and opaque, outline, wireframe or
debug material substitutions may reveal removed faces. The previous probe's
shadow failure is an intentional known compatibility tradeoff here, not a
regression being described as a pass. No target application was tested.

## Final-byte default-rendering verification

The candidate SHA was frozen before capture. Using three 0.186.1, three-vrm
3.5.5 and Playwright 1.51.1, all **270 PNGs are byte-identical to the third trial**:
78 standard frames, 129 dense blink/emotion/wink closeups and 63 saved motion
frames. The motion suite samples three 3-second, 60 Hz neck/chest/arm/blink
sequences from front, oblique and profile. All 672 dense/motion state records,
bone matrices, effective expressions, UV transforms and projected lid bounds
match; no runtime errors or nonfinite states occur.

Actual skinned lid boxes/spheres match in 12 poses × 5 blink weights (360 lid
comparisons), and all 252 mesh-pose position streams match byte-for-byte.
These tests cover the default color renderer, not arbitrary host render passes.

## Explicit shadow OFF / forced ON comparison

The final-file diagnostic uses 33 matched angle/light/blink states per mode,
with a shadow receiver and otherwise unchanged materials. Together with one
additional full-body state, all 34 OFF pairs are PNG-byte-identical. All 34 host-forced ON pairs differ: at most 2,083 of 810,000
pixels (0.2572%) change in a frame, and maximum channel difference reaches
139/255 in a different side-lit frame. These are localized but real differences,
not parity. Additional matched full-body images accompany the enlarged regions.

The runtime audit confirms 21 imported meshes normally have shadow casting and
receiving disabled, all material flags and computed bounds match, and no custom
depth/distance material is installed. The forced mode enables casting/receiving
and uses the stock Three.js shadow path, which omits vertex alpha. No MToon or
asset-defined outline shader exists. This explains this diagnostic result; it
does not predict every application's shader overrides.

The editable Blend passed save/reopen plus a separate verify-only process using
Blender 5.1.2 and VRM add-on 4.7.2. All native vertices/edges, surviving face and
corner data, bounds, unrelated meshes, rig, materials and packed images remain.
Independent final review approves the explicitly conditional experiment only.

## Adoption and editing conditions

Compare the fourth experiment with the third trial in the actual application's
lighting, shadow and outline settings, including blink, expressions and motion.
Use the third trial if the changed shadow/outline behavior is unwanted. Do not
infer an FPS gain, universal appearance equality or all-motion certification.

The editable Blend preserves native retained data and removes faces only.
Native lid normal/UV/color values already differ from the post-export VRM in the
third trial; those inherited differences are measured, not silently repaired.
Fourteen deleted native faces have tiny pre-export alpha (at most 5.8423e-6),
which had quantized to exact zero in VRM. The builder follows the authoritative
VRM face subset without modifying retained alpha. The largest retained native
normal-component difference is 8.9944e-5, unchanged by pruning.
The delivered VRM is runtime authority. An ordinary Blender GUI export is not
an exact reproduction route.

## Private recovery and reproduction

| Item | Library reference | SHA-256 |
| --- | --- | --- |
| Experimental VRM | `libfile_356e4026f8a08191bec0ec8502a521b0` | `8a21c6044fee2cf51a0546be57cad07d7ff59f7d47778b89c5a3e58ee93166c8` |
| Editable Blend | `libfile_05b9d08100088191a085298315320fbf` | `f24a861b2187251c71da1a66b15d2cb29f0963b0bfb2d994b7692cd13f47816e` |
| Reproduction ZIP | `libfile_16589112bc6c8191b5c21ac03637ac89` | `4649fcc1ddf2a7f942e37fa72753eaf73b5176ba47bb52149fc1f44d1287bbed` |
| Shadow OFF/ON comparison | `libfile_1072f3d093348191b6ea987da968ff33` | `063dc6a9eb597e7323d903f2ccd19042ebd4f7732d73c1fa3f5a6b6e1f79c255` |

Models, binary layouts and evidence images remain private and excluded from Git.
Materialize the kit under ignored `artifacts/`, check its hash, and replay from
[accepted K](FINAL_2026_10_12.md) with Python 3 and NumPy:

```sh
python scripts/apply_layouts.py "$MIINEKO_K_VRM" layouts new-output/experimental-v4.vrm
```

The selected-layout replay checks the exact output hash and does not need a
previous trial. The optional face-only Blend build uses the frozen third-trial
Blend; the kit documents its source identity and separate save/reopen validation.
The shadow diagnostic and default-runtime checks are reproducible separately so
the conditional result cannot be mistaken for universal rendering parity.
