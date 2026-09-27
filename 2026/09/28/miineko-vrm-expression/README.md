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
mise run mask-uv-blink-probe
export MIINEKO_BASECOLOR=/path/to/original-BaseColor.jpg
# With requirements-compare.txt installed in the selected Python environment:
mise run atlas-probe
# In an environment with requirements-compare.txt installed:
mise run compare-mask
```

`mask-probe` copies selected face triangles and keeps the original UV for its neutral material. `bake-probe` transfers the original BaseColor into a new 4096² face-local UV. `blink-cap-probe` uses copied eye triangles; `prosthetic-probe` uses a smooth fitted eyelid and a local eye-recession Shape Key. `mask-uv-blink-probe` is the separate full-mask texture-switch experiment described below. These are visual prototypes only; they do not create VRM expressions. The measured neutral comparison is in [`results/mask-render-comparison.json`](results/mask-render-comparison.json). The input FBX, rendered images and `.blend` files remain local and are not published.

`atlas-probe` requires `bake-probe` and `mask-uv-blink-probe` outputs. It creates one shared BaseColor atlas and renders the two expression blocks through a UV mapping offset. The atlas, previews and `.blend` stay in ignored `artifacts/` because they contain private source imagery.

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

The mask is a copy of 1,480 front face polygons from the existing Tripo face, including the eye side surfaces, displaced outward by 0.8 mm. It carries the original UV plus a new planar and an angle-unwrapped face-local UV. The original head remains in place.

The rendered neutral mask stayed close to the original numerically: the face-region RGB mean absolute error was **0.495/255**, and **1.10%** of face-region pixels differed by more than 12 in any channel. The body control was **0.076/255**. However, visible short seams appeared on the cheeks where the copied mesh ends. The neutral mask therefore **does not pass the visual acceptance gate**, despite the low aggregate error. This is evidence that the surface can be copied accurately, not that a permanently visible full-face shell is finished.

The 4096² local-UV BaseColor bake was worse: face error **2.202/255**, with **4.91%** changed pixels, concentrated at eye/nose/mouth rims (face-core error **5.661/255**). Raising the bake from 2048² to 4096² did not visibly fix the feature edges. A simple planar local UV was also worse than the angle-unwrapped version. The cause has not been isolated; UV discontinuities, overlapping source geometry and other material maps are candidates. A rebaked shell should not replace the neutral surface yet.

For a blink, copying the original eye triangles into a colored lid left jagged boundaries and exposed dark edges. A second prototype fitted a smooth polar patch to an approximate quadratic skin surface around each eye and used a local Shape Key to push only protruding eye vertices behind it. Its **neutral render is pixel-identical within the renderer's one-level noise** because the patch is hidden and the Shape Key is zero. Its closed-eye render still has a raised circular rim and central artifacts. The fitted surface is only an approximation of this model's head, not a general facial reconstruction algorithm. No VRM export or independent viewer check was done for this prototype.

The closed-eye prototype has **no closed-eye image texture and no UV animation**. At neutral, the original FBX head samples its original BaseColor atlas; the full-face copied mask and the prosthetic eyelids are hidden. At blink, the original eye vertices are locally pushed back, and the two new eyelids are rendered with a constant pink material, vertex-alpha fade at their edges, and separate dark curve objects as eye lines. The 4096² face-local image belongs only to the separate bake experiment and is not used by the blink prototype. This distinction matters: the poor closed-eye appearance is caused by the rough geometry/material transition, not by a failed animated texture.

### Actual full-mask UV texture switch

After reviewing that mismatch, `mask-uv-blink-probe` used the **full conformal mask** for both states. It rasterizes the selected eye regions into a copy of the original 4096² BaseColor atlas using each source triangle's UV and 3D coordinates. The modified pixels replace the black eyes and highlights with forehead-sampled pink and a curved dark eye line; every other pixel is copied from the original. Blender switches only the mask's BaseColor image between the original and the generated `artifacts/mask-uv-blink-texture.png`. The UV layout and all geometry, including the eye protrusion, stay fixed. There is no separate eyelid mesh or Shape Key in this test.

The neutral render (`artifacts/mask-uv-neutral.png`) matches the neutral full-mask probe. The closed render (`artifacts/mask-uv-blink.png`) proves that the texture switch reaches both eyes on the original UV layout, but **does not yet look like an eyelid**: the eye sockets have a hard circular transition, small sculpted eye details remain visible, and the painted skin/line do not follow a convincing lid boundary. The new texture does not remove relief already present in the mesh and normal map. The owner's point is also correct: a human eyelid does not erase the eye's overall bulge. The next geometry work, if needed, should smooth the local rim and sculpted highlights while retaining the rounded volume, rather than flattening the eye.

This is a Blender material-image switch, **not yet a VRM `TextureTransformBind` or a lip-sync test**. To encode this as VRM 1.0, the two states would need to share a compact atlas and a material isolated to the mask; the original FBX's single material cannot be transformed wholesale. Independent left/right blinking and mouth states require further material/atlas planning.

### One-image atlas with aligned expression blocks

The subsequent `atlas-probe` implements that layout for **BaseColor** in an 8192 × 4096 image:

| Pixel region (top-left origin) | Contents | UV mapping |
| --- | --- | --- |
| `x=0…4095, y=0…4095` | Original 4096² Tripo atlas | Body `u'=0.5u`, `v'=v` |
| `x=4096…6143, y=0…2047` | Mask neutral, 2048² | Mask `u'=0.5+0.25u_local`, `v'=0.5+0.5v_local` |
| `x=6144…8191, y=0…2047` | Mask blink, 2048², same local UV structure | Neutral mask mapping plus `0.25` in U |
| Right-half bottom row | Empty, reserved for later expression blocks | Not tested |

The original atlas and both expression blocks are in **one PNG** (`artifacts/miineko-expression-atlas.png`). The body and mask use separate materials but reference the same image, so only the mask material's UV transform changes. In Blender, `atlas-neutral.png` and `atlas-blink.png` were rendered from the same scene and atlas with the mask mapping location changing from `(0.5, 0.5)` to `(0.75, 0.5)`. The body did not move. This validates the requested **layout and switching mechanism** in Blender; it does not validate visual quality or VRM export.

The neutral and blink blocks were baked from the original scattered UV layout into the same face-local UV and then reduced to 2048². They therefore inherit the earlier rebake defects, with further softness from downsampling. The atlas render still shows the face-mask seam, and blink still exposes the source eye's sculpted ring. This prototype uses the original normal/roughness/metallic maps on the body and a simpler mask material; it is **one BaseColor image**, not one image for every material property. The [VRM 1.0 expression specification](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/expressions.md) applies Texture Transform to a material's UV-accessed textures, so a production mask must either pack its other maps into matching blocks or omit them deliberately. A full set of 17 expression states would also require a larger atlas, smaller blocks, or multiple separately controlled materials/images; this 8192 × 4096 two-state proof does not settle that tradeoff.

**Interpretation:** the full conformal mask can carry texture variants while preserving the original UV and eye volume. It also retains the original sculpted eye ring, so painted variants alone cannot guarantee a natural blink. The hidden-patch route remains a separate fallback. Clean transitions, side views, independent left/right control, mouth motion and VRM binding remain unsolved.

## Next experiment and acceptance gate

1. Refine the full-mask closed texture and the local eye-ring/normal transition while retaining the eye volume. Make the neutral and blink states visually acceptable from front and side before adding more expressions.
2. Render original FBX and modified neutral model with identical camera, lighting and pose from front, side and back. Require the body, ribbon, head silhouette and neutral face to match visually. The full-mask neutral front render is close numerically but still has small cheek seams.
3. Build a compact atlas and isolate the mask material. Test `TextureTransformBind` on it and preserve other maps when shifting UVs. Verify left/right blink independently.
4. Extend the same mask approach to mouth texture states, adding only local geometry correction needed for readable lip shapes. Check the results in Blender **and** an independent VRM viewer, including combined emotion + blink + lip-sync.

This lab concludes that direct UV offset of the original material and a permanently visible **rebaked** full-face shell are unsuitable in the tested form. A full face mask using the **original UV** can switch its BaseColor without replacing the head, but its first closed-eye variant is visually poor. A material-isolated VRM atlas and mouth states are still unvalidated.
