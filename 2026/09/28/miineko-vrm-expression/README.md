# Preserving a Tripo VRM face while adding expressions

## Question

Can VRM 1.0 facial expressions be added to a Tripo-rigged Miineko model **without replacing the head and losing the generated appearance**? This lab records the failed replacement-head attempt and probes a conformal face mask with local UVs and detachable eyelids.

## Inputs and environment

- Input: a private Tripo Multi-view → H3.1 HD Model → Quad Smart Mesh Retopo (10,000 target) → VRM 1.0 Humanoid FBX, with BaseColor, Normal, Metallic and Roughness textures. The FBX is owned by the private `kiarina/assets` repository (`miineko/tripo/v1/`, source commit `280b18f`). It is not redistributed here.
- Input FBX SHA-256: `1902b3712bc8de441ade04ff951123e65bd5b8d243c498fdb3bf433dfa53297b`.
- Tested on 2026-09-28 with Blender 5.1.2, VRM Add-on for Blender 4.7.2, macOS arm64.
- Render comparisons use Python 3.13.12, NumPy 2.4.3 and Pillow 11.3.0, with Blender Cycles at 900 × 900 and 32 samples. The camera, lights and pose are fixed in the probe scene.
- Archived failed outputs, local only: `artifacts/miineko-v1.blend` (SHA-256 `28a8ebca1fccded471a6a36fd51f2ccaa9d00407b488e2331ff80495a58093bf`) and `artifacts/miineko-v1.vrm` (SHA-256 `0f5d967864fc5a6a2c22a65a9659ee3193b84fe014a6df463ea99ba85be4ad0f`), plus three preview PNGs. `artifacts/` is ignored because the source design is private and the binaries are large. These files were moved here from `assets/miineko/tripo/v1/` after review; the original Tripo FBX remains in `assets`.

## Reproduce and inspect

The static check uses the recorded UV measurements and needs no private input:

```sh
mise run
```

With authorized local access to the FBX and Blender installed, rerun the inspected failure path:

```sh
export MIINEKO_FBX=/path/to/tripo-rigged.fbx
export BLENDER_BIN=/path/to/Blender
mise run reproduce
```

`reproduce` imports the FBX, records its UV/material structure, assigns VRM humanoid bones, runs the face replacement build, exports VRM 1.0, reimports it, renders expression previews, and advances the SpringBone simulator. It writes only to ignored `artifacts/`. It does not call Tripo or an image-generation API. The rebuilt VRM is structurally equivalent for this experiment but was not byte-identical to the archived VRM; the exported `.blend` and `.vrm` are therefore preserved as the reviewed samples.

The mask probes are separate from `reproduce`. They render the original FBX and each prototype to ignored local files:

```sh
export MIINEKO_FBX=/path/to/tripo-rigged.fbx
export BLENDER_BIN=/path/to/Blender
mise run mask-probe
mise run bake-probe
mise run blink-cap-probe
mise run prosthetic-probe
# In an environment with requirements-compare.txt installed:
mise run compare-mask
```

`mask-probe` copies selected face triangles and keeps the original UV for its neutral material. `bake-probe` transfers the original BaseColor into a new 4096² face-local UV. `blink-cap-probe` uses copied eye triangles; `prosthetic-probe` uses a smooth fitted eyelid and a local eye-recession Shape Key. The latter two are visual prototypes only; they do not create VRM expressions. The measured comparison is in [`results/mask-render-comparison.json`](results/mask-render-comparison.json). The input FBX, rendered images and `.blend` files remain local and are not published.

## Observations

### Original Tripo asset

The FBX contains one connected mesh: 8,937 vertices, 9,186 polygons, **one material**, one UV layer, and **no Shape Keys**. This is a good textured static face, but the eye and mouth geometry are welded into the head. The two Tripo face-eye control bones were not symmetric in the imported rest pose. A simple mapping of VRM preset names does not create facial motion.

[`results/uv-inspection.json`](results/uv-inspection.json) measures rough spatial face regions in Blender coordinates. The selection is approximate, not a semantic segmentation:

| Region | Polygons | UV islands within selection | UV bounds |
| --- | ---: | ---: | --- |
| Left eye area | 227 | 18 | U `0.013–0.955`, V `0.030–0.979` |
| Right eye area | 255 | 26 | U `0.026–0.962`, V `0.002–0.955` |
| Nose and mouth area | 436 | 58 | U `0.002–0.777`, V `0.001–0.989` |

The wide bounds and numerous islands mean the eye and mouth faces do not occupy simple contiguous rectangles of the existing atlas. A single offset applied to the original UV layout is not a practical expression switch.

### Failed Blender route

The attempt tried direct eye Shape Keys, eye/mouth overlays, local surface replacement, and finally replacement of the whole head with movable eye, nose, mouth and ear meshes. Earlier direct eye compression produced triangular closed eyes. Overlays made the neutral eyes look doubled or exposed the original black rims. Local replacement left visible boundaries; whole-head replacement removed the original Tripo face appearance. The final failed sample has 17 nonempty Expression bindings, Bone-type LookAt, and three two-joint SpringBones, and reimports as VRM 1.0. The SpringBone update rotated both ears and tail. These structural checks **did not establish acceptable visual quality**. The owner rejected the result after viewing it in an independent VRM viewer because it degraded the Tripo appearance.

The FBX lower-leg and foot bone directions were also unsuitable for a VRM rest skeleton. The first VRM round-trip deformed the legs; correcting those bone directions fixed that separate issue. This is not evidence that the facial-expression approach works.

## Texture Transform feasibility

The [VRM 1.0 expression specification](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/expressions.md) defines `textureTransformBinds` by **material**: one scale/offset affects all UV-accessed textures of that material. The original FBX uses the same material for head, eyes, mouth, bow and body. Binding a transform directly to it would move the whole character's texture, including nonfacial maps. The [VRM 1.0 LookAt specification](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/lookAt.md) explicitly permits Texture Transform for expression-based gaze.

**Inference from the specification and this FBX:** keeping the original head while using UV expressions requires independently addressable face materials, whether by splitting selected original polygons or by attaching separate mask meshes. At minimum, left eye, right eye and mouth need independent control so `blinkLeft` and `blinkRight` do not change the entire face. A full expression atlas has **not** yet been built or visually validated. Material reassignment can preserve geometry, but a new atlas and UV remapping/baking are substantial work because the current islands are scattered.

Texture changes cannot flatten protruding eyes or open a mouth in 3D. A useful hybrid would use UV switching for color/eye direction and small, localized Shape Keys or separate eyelids for the silhouette changes. The earlier failure of a global head reconstruction does **not** prove that every local Morph Target is unsuitable; it shows that naive deformation of the welded eye surface was unsuitable.

## Conformal mask probes

The mask is a copy of 1,359 front-facing polygons from the existing Tripo face, displaced outward by 0.8 mm. It carries the original UV plus a new planar and an angle-unwrapped face-local UV. The original head remains in place.

The rendered neutral mask stayed close to the original numerically: the face-region RGB mean absolute error was **0.586/255**, and **1.38%** of face-region pixels differed by more than 12 in any channel. The body control was **0.075/255**. However, visible short seams appeared on the cheeks where the copied mesh ends. The neutral mask therefore **does not pass the visual acceptance gate**, despite the low aggregate error. This is evidence that the surface can be copied accurately, not that a permanently visible full-face shell is finished.

The 4096² local-UV BaseColor bake was worse: face error **2.214/255**, with **4.95%** changed pixels, concentrated at eye/nose/mouth rims (face-core error **5.688/255**). Raising the bake from 2048² to 4096² did not visibly fix the feature edges. A simple planar local UV was also worse than the angle-unwrapped version. The cause has not been isolated; UV discontinuities, overlapping source geometry and other material maps are candidates. A rebaked shell should not replace the neutral surface yet.

For a blink, copying the original eye triangles into a colored lid left jagged boundaries and exposed dark edges. A second prototype fitted a smooth polar patch to an approximate quadratic skin surface around each eye and used a local Shape Key to push only protruding eye vertices behind it. Its **neutral render is pixel-identical within the renderer's one-level noise** because the patch is hidden and the Shape Key is zero. Its closed-eye render still has a raised circular rim and central artifacts. The fitted surface is only an approximation of this model's head, not a general facial reconstruction algorithm. No VRM export or independent viewer check was done for this prototype.

**Interpretation:** the promising architecture is to leave the original head visible at rest and reveal small expression-specific prosthetic surfaces only when needed. Each surface can have compact local UVs and a dedicated material. Local geometry deformation handles occlusion and silhouette, while UV/texture changes handle ink, iris direction and expression detail. This avoids a full neutral rebake, but clean transitions, side views, independent left/right control, mouth motion and VRM binding remain unsolved.

## Next experiment and acceptance gate

1. Keep the original Tripo head and rig visible at neutral. Fit small eye and mouth prostheses, with dedicated materials and local UVs, and hide them at zero expression. Remove the visible rim and center artifacts from the closed eyelid before expanding the approach.
2. Render original FBX and modified neutral model with identical camera, lighting and pose from front, side and back. Require the body, ribbon, head silhouette and neutral face to match visually. The hidden-patch neutral front render passes numerically; side/back and the closed state do not yet pass.
3. Build a compact atlas for each independently controlled eye and mouth surface. Test `TextureTransformBind` on those materials and preserve other maps when shifting UVs. Verify left/right blink independently.
4. Add only the local geometry correction needed for a closed eyelid and open mouth. Check the results in Blender **and** an independent VRM viewer, including combined emotion + blink + lip-sync.

This lab concludes that direct UV offset of the original material and a permanently visible rebaked full-face shell are unsuitable in the tested form. The hidden prosthetic mask plus local geometry and UV control is a plausible route, **not a validated VRM solution**.
