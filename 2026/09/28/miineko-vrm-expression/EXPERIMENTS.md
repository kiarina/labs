# Continuous blink comparison

## Question and scope

Can the original neutral face remain unchanged while a rounded eyelid closes
continuously, using only controls supported by VRM 1.0? A half blink must be a
partially covered eye, not the midpoint between unrelated texture atlas tiles.

The first experiment compares the original mesh, identical materials assigned
to eye regions without rebaking or mesh duplication, and a continuous UV alpha
wipe on a smoothed local eye shell. A local retopology/morph lid is a separate
candidate if the alpha surface cannot meet the visual gate. Whole-head replacement
is excluded from this comparison. These are hypotheses, not established recipes.

## Acceptance and stopping

- Compare neutral, 0.25, 0.5, 0.75 and closed, from front, 45 degrees and side.
- Neutral must retain source details; inspect both pixel differences and edges.
- Intermediate states must reduce the visible opening without intersections.
- Closed must retain eye volume without sculpted highlight cavities or black rims.
- Reject visible seams, detached surfaces and double lid lines.
- Test a small exported VRM in an independent viewer before adding mouth/emotions.
- Preserve inputs and parameter values; rerun from the source FBX to check repeatability.
- Human selection of landmarks is allowed if saved and reproducible. Fully automatic
  transfer to unrelated characters is outside the first acceptance gate.

## Rationale

The existing two-tile atlas proves endpoint addressing, not continuous blink.
VRM texture transforms interpolate offsets. An intermediate offset samples between
tiles. The wipe candidate instead moves a transparent/ink/skin boundary over a
fixed surface. Original body maps and UVs remain untouched.

References: [VRM expression specification](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/expressions.md),
[three-vrm texture transform implementation](https://github.com/pixiv/three-vrm/blob/dev/packages/three-vrm-core/src/expressions/VRMExpressionTextureTransformBind.ts).

## Observed results (2026-09-28)

These are successive exploratory prototypes, not a controlled benchmark where
only one variable changes. Earlier failures remain in ignored `artifacts/`.
The source FBX and all character images/models remain private.

| Candidate | Observation and disposition |
| --- | --- |
| Identical material copies on original eye polygons | No rebake or mesh copy is necessary to isolate eye materials. Neutral differences stayed within one 8-bit level in all three views. Useful control; it does not itself animate the face. |
| UV coverage on a fixed rounded shell | Continuous blink and independent sides work in VRM/three-vrm. The intermediate lid edge can look like a floating shelf. Closed-eye material/surface transitions are visible. Not visually accepted. |
| Source-obstacle smoothing | Fills cavities but retains facets. The earliest export also lost feather alpha, so that run cannot isolate geometry quality from material-export behavior. Rejected. |
| Smooth eye fit and source-sampled skin color | Removes highlight dents and improves surface smoothness, but an enclosing offset increases bulge. Curved edges and a wider opaque region reduce black leakage. Still not accepted. |
| UV coverage plus a small source-eye clearance morph | Reduces the need to move the shell forward. Neutral is preserved in the independent viewer. Boundary/shading problems remain in half and closed states. Reproducible runtime control, not a finished eyelid. |
| Collapsed moving lid meshes | Morph binding works, including intermediate weights. Side views show floating edges. Not accepted. |
| Regular eye grids over recessed original faces | Can compress the markings to a squint, but moving the old vertices made rectangular trenches. Reducing the recession improves but does not remove the interface. Rejected. |
| Locally stitched eye patches | Removes source eye faces and reuses the actual boundary vertices. Low angular resolution made eye contours jagged; denser rings improved them. Source normal transfer greatly improves the neutral eyes, but interpolating deformations still needs work. Experimental. |

### Verified runtime and reproducibility

The `continuous-fresh` run starts from the original FBX, not a previously edited
model. Blender 5.1.2 and VRM Add-on 4.7.2 build a hybrid candidate, then Chrome with
three 0.186.1 and three-vrm 3.5.5 renders five blink weights from three angles,
plus independent left/right blink. The viewer uses the exported VRM expressions;
it does not recreate the effect through a custom viewer shader.

- The viewer baseline is a separately loaded original-face `base-vrm.vrm`, with
  the same lighting, camera and runtime update. No Blender/three-vrm pixel parity
  is claimed; their lighting/color pipelines differ.
- In that viewer, neutral front/side pixels match the baseline exactly. The
  oblique view differs by at most one 8-bit channel level.
- Cycles neutral comparisons are not exactly equal: mean RGB differences are
  approximately 0.0973/255, 0.0716/255 and 0.0216/255 for front/45°/side. The
  transparent surfaces affect the rendering path. These measurements do not
  override the visual gate.
- Repeating the hybrid build from the frozen base produced an identical VRM
  binary. All 15 Cycles images differed by at most one 8-bit level. Regenerating
  the base from the FBX and running the complete task also produced the same VRM
  binary. This establishes repeatability for this input/toolchain only.
- Structural checks decode actual exported `COLOR_0` alpha, require continuous
  expressions, and inspect left/right material and morph-target assignments.
  Browser error checks are supplemented by inspection of the captured images.
- Blender reimport retains the hybrid texture/morph bindings and the stitched
  left/right morph bindings. This is a binding-import check, not a claim that
  Blender preserves the explicitly patched per-target normal fields on re-export.

The committed measurements are in
[`results/continuous-blink-evaluation.json`](results/continuous-blink-evaluation.json).

### What the failures isolated

1. Blender's glTF exporter did not recognize the older `ShaderNodeMixRGB` path
   as the needed color/alpha combination. Early files had a white `COLOR_0`
   with alpha=1 and useful feathering in `COLOR_1`. A supported `ShaderNodeMix`
   RGBA multiply path exports the real color and alpha into `COLOR_0`.
2. A texture offset interpolates continuously; moving between two unrelated
   atlas tiles cannot synthesize half-open eyes. A moving alpha boundary can.
3. A radial fade that overlaps black eye pixels necessarily reveals the source
   outline. Opaque coverage and surface-fitting extent need separate control.
4. Color-only transfer is insufficient for neutral fidelity. Unlit comparison
   of the stitched patch stays close to source colors while lit comparison
   exposes faceting. Transferring source tangent-space normal-map information
   into patch normals improves the lit neutral face.
5. A closed surface and its normals need their own definition. The stitched
   normal experiment writes standard glTF NORMAL morph deltas. All 36,668
   intended new vertices in the narrow-patch test matched the exported positions;
   this is a structural check, not proof of visual quality.
6. Ring-index-based deformation inherited the irregular source boundary's
   variation. A physical-coordinate falloff reduced that coupling, but the narrow
   region did not compress all black pixels. Widening the stitched region to
   0.14 × 0.15 m removed that black remainder; the endpoint still has a visible
   raised ring and shading defects. This wider candidate is **also rejected as a
   finished face**. Its neutral eye contours are slightly softer than the source.

## Reproduce the runtime-verified hybrid

Install the exact viewer dependencies with `npm ci`. Install comparison packages
from `requirements-compare.txt` into a local virtual environment. Set
`MIINEKO_FBX`, `BLENDER_BIN`, `COMPARE_PYTHON`, and optionally `CHROME_BIN` to local
paths. The original private input and compatible Blender/VRM Add-on are required.

```sh
export BLINK_RUN=continuous-fresh
mise run continuous-probe
```

Outputs are `artifacts/$BLINK_RUN/`: editable `.blend`, `.vrm`, Cycles comparisons,
`viewer/` screenshots and runtime logs, and `measurements.json`. This task does not
call an image-generation service or Tripo. A successful task means the experiment
ran, **not** that it passed the visual acceptance gate.

The other probes consume the prepared `artifacts/base-vrm.blend` and, for the
retopology probes, the studio in `artifacts/mask-probe.blend`. Both are regenerated
by `continuous-probe`:

```sh
# Moving shell: endpoint shape shared with the UV candidate, different motion.
BLINK_RUN=morph-probe BLINK_METHOD=morph BLINK_SURFACE=quadratic-eye \
  "$BLENDER_BIN" --background --python-exit-code 1 --python scripts/continuous_blink_probe.py

# Stitched local eye surface, explicitly experimental.
BLINK_RUN=stitched-probe BLINK_NORMALS=morph BLINK_CLOSED_SURFACE=smooth \
  BLINK_WARP=physical STITCH_RX=.14 STITCH_RZ=.15 \
  "$BLENDER_BIN" --background --python-exit-code 1 --python scripts/stitched_blink_probe.py
BLINK_RUN=stitched-probe "$COMPARE_PYTHON" scripts/apply_morph_normals.py
BLINK_RUN=stitched-probe node scripts/verify_viewer.mjs
"$COMPARE_PYTHON" scripts/measure_blink_probe.py stitched-probe
```

`apply_morph_normals.py` retains the raw exporter result as `before-normal-patch.vrm`
and writes explicit glTF NORMAL deltas to the viewer file. Repeating this step uses
that raw input rather than repeatedly appending to the patched output. Blender
renders in this experiment use evaluated mesh snapshots with the corresponding
interpolated normal field; the saved editable blend retains its source normals.
The patched VRM must be checked in the independent viewer; do not infer success
from the editable blend alone.

For interactive inspection, serve this lab on loopback and open
`viewer.html?model=continuous-fresh`. The slider, individual eye selector, three
view angles and original-model toggle work locally. No character files are
uploaded. Rendered media and binaries are intentionally not in Git.

## Remaining acceptance work

No candidate is yet accepted as the production method. Do not add the remaining
expressions on top of an unsuccessful blink. The next comparison must separate
the closed surface, boundary continuity, coverage, and shading rather than changing
all of them at once. Keep source-preserving UV coverage as the runtime reference;
use the stitched experiments to diagnose local geometry and normal transfer.
Mouth shapes, gaze, combined expressions and integration of springs remain after
the blink/neutral quality gate. Cross-character transfer and other VRM runtimes
remain unverified.
