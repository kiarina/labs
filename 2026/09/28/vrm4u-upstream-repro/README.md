# VRM4U upstream bug reproductions (UE 5.8)

[VRM4U](https://github.com/ruyo/VRM4U) is the VRM importer and runtime loader
for Unreal Engine. A shipping UE 5.8 game carries a set of local patches on top
of VRM4U `20260622`. This lab checks, against the current upstream master,
whether four of those patches still fix real defects, and produces the evidence
for upstream pull requests. It is a minimal Blank C++ project that
runtime-loads the VRM Consortium's Seed-san sample and measures what happens.

## Questions

1. **Runtime load without `GEditor`:** does runtime conversion crash when an
   editor build runs with `-game` (issue
   [ruyo/VRM4U#533](https://github.com/ruyo/VRM4U/issues/533))?
2. **Post-process AnimBlueprint:** does runtime conversion in PIE or `-game`
   assert while creating `ABP_Post_<name>` for a transient mesh?
3. **Material update context:** how much does the per-material
   `FMaterialUpdateContext` cost a runtime load, and does removing it change
   the rendered image?
4. **VRM 1.0 spring bones:** does VRM4U follow VRMC_springBone 1.0's Head/Tail
   joint pairs, including a Tail that is not the Head's direct child?

## Method

Pinned inputs are in [`pins.env`](pins.env): VRM4U master `615e632`
(2026-09-24), the assimp fork VRM4U links against, and Seed-san
(VRM 1.0, [VRM Public License 1.0](https://vrm.dev/en/licenses/1.0/index),
downloaded at run time and not redistributed).
`Seed-san-thinned.vrm` is derived by
[`scripts/thin_spring_joints.py`](scripts/thin_spring_joints.py): it keeps
every other joint of each spring, so the skipped nodes stay in the skeleton as
plain nodes between a Head and its Tail. The specification allows this.

Each variant starts from the pristine pinned tree, applies patches from
[`patches/`](patches/) and rebuilds the Editor target:

| Patch | What it changes |
|---|---|
| `00-mac-build` | Build fix only: a lambda parameter shadowed a member (`-Werror,-Wshadow` on Xcode). Applied to every variant |
| `01-runtime-curve-metadata-no-transaction` | Runtime conversion adds morph curve metadata without an editor transaction |
| `02-runtime-skip-postprocess-abp` | Runtime conversion does not create the post-process AnimBlueprint |
| `03-runtime-skip-material-update-context` | Runtime conversion does not build a `FMaterialUpdateContext` per material |
| `04-vrm1-spring-head-tail-axis` | VRM 1.0 spring: Head→Tail axis, tail starts at the Tail, chains across plain nodes |

The C++ driver ([`VrmReproDriver.cpp`](UnrealProject/Source/VrmRepro/VrmReproDriver.cpp))
reads the command line, calls `ULoaderBPFunctionLibrary::LoadVRMFileFromMemory`
and writes `results/<name>.json`:

- **load:** time the conversion. `--filler N` first registers N static mesh
  components, each with its own material instance, to stand in for a populated
  world. `--shot` also renders the model from a fixed camera and saves a PNG
  (anti-aliasing, motion blur and auto exposure are off for this lab so the
  images are deterministic).
- **spring:** drive the mesh with VRM4U's `FAnimNode_VrmSpringBone`, the way
  `UVrmAnimInstanceCopy` does ([`VrmReproAnimInstance.cpp`](UnrealProject/Source/VrmRepro/VrmReproAnimInstance.cpp)).
  Gravity, wind and VRM colliders are switched off to isolate the solver.
  After 2 s at rest the actor accelerates to 150 cm/s along +X; the result is
  each spring's mean tail offset along X over the last second of cruise
  (negative = the chain trails behind).
- **import (Editor):** [`init_unreal.py`](UnrealProject/Content/Python/init_unreal.py)
  imports the model with `ImportVRMFileWithOptions` and reports the created
  mesh and post-process AnimBlueprint.

[`scripts/spring_axis_report.py`](scripts/spring_axis_report.py) compares, on
the rest skeleton, the axis the specification defines (Head → Tail) with the
one VRM4U uses (Head's parent → Head).

## Reproduce

macOS arm64, Unreal Engine 5.8, Xcode, CMake. One full pass takes about 30
minutes and opens Editor and game windows.

```sh
export UE_ROOT=/path/to/UE_5.8
mise run setup            # fetch VRM4U, build assimp (no patches)
mise run fetch-model      # Seed-san + thinned variant
./scripts/run_matrix.sh   # every variant and run below → results/summary.md
```

Single runs: `mise run setup 00-mac-build 02-runtime-skip-postprocess-abp`,
`mise run build`, then `mise run run <game|pie|import> <load|spring> <name>`.

## Results

Environment: Mac Studio M4 Max 128 GB, macOS 26, Xcode 27.0, Unreal Engine
5.8.2. Full tables: [`results/summary.md`](results/summary.md); per-run JSON
and trimmed logs are next to it.

### 1 and 2: runtime load crashes

| Variant | `-game` | PIE |
|---|---|---|
| upstream (00) | crash in `UAnimBlueprint::SetPreviewMesh` ← `VRMConverter::ConvertModel` | same crash |
| 00+02 | crash in `UEditorEngine::BeginTransaction` ← `AddCurveMetaData` ← `AccumulateCurveMetaData` ← `ConvertMorphTarget` (the #533 stack) | loads |
| 00+01+02 | loads (0.87 s) | loads |

- The `ABP_Post_` block runs under `WITH_EDITOR`, so it also runs in `-game`
  on an editor build, and it fails first.
- With only the morph-target call fixed, the next crash had the same cause in
  `VrmConvertPose.cpp` (`GetUniquePoseName` → `AddCurveMetaData(NewName)` with
  the default `bTransact=true`). Patch 01 covers both call sites.
- Editor import is unchanged by 01+02: both upstream and 00+01+02 create
  `ABP_Post_Seed-san` and 43 morph targets. Both import runs log one ensure
  (`EditorModeToolsSingleton.IsValid()` in `~SLevelEditor`) while the harness
  quits the Editor; it appears with and without the patches.

### 3: material update context (PIE)

| Variant | 0 extra components | 2000 extra components |
|---|---|---|
| 00+02 | 0.613 s, 0.592 s | 1.467 s, 1.484 s |
| 00+02+03 | 0.560 s, 0.561 s | 0.563 s, 0.570 s |

Without the patch the load cost grows with the number of components in the
world: each of Seed-san's 17 materials recreates every component's render
state and flushes the rendering thread. With it the cost stays flat.
Screenshots with and without the patch are identical (max channel difference
0; same as two runs of one variant).

An earlier pass with anti-aliasing on measured 2.17–2.25 s at 2000 components
before the patch and 0.55 s after. The images then differed by 0.17 % of
pixels, all single pixels along edges, and two runs of one variant by
0.005–0.010 %. With anti-aliasing off the difference is zero, so it was
temporal jitter at a different frame, not a material change.

### 4: VRM 1.0 spring bones (PIE)

Model for this part: VRoid's official sample **AvatarSample_E** (VRM 1.0, 45
springs / 173 joints; sha256 `6a6237bc…abdfec1`). It is not redistributed here:
place it at `.cache/models/AvatarSample_E.vrm` and derive the thinned variant
with `scripts/thin_spring_joints.py`. The runs are in `scripts/run_matrix.sh`
under "AvatarSample_E".

**Axis.** Across AvatarSample_E's 128 Head/Tail pairs the axis VRM4U uses
differs from the specification's by a median of 3.3°, by more than 90° on 17
pairs, and by 110°–141° at the root of all ten hair strands (`J_Sec_Hair1_*`:
the specification points down the strand, VRM4U points from the head centre
to the root) ([`results/spring-axis-AvatarSample_E.txt`](results/spring-axis-AvatarSample_E.txt)).

**Response while cruising** (gravity, wind and colliders off; tail offset
along X, negative = trails behind):

| Spring | Joints | upstream (00+02) | 00+02+04 |
|---|---|---|---|
| J_Sec_Hair1_01 | 4 | −7.66 cm | −17.40 cm |
| J_Sec_Hair1_10 | 5 | −21.99 cm | −38.66 cm |
| J_Opt_C_RabbitTail1_01 | 4 | −16.42 cm | −25.05 cm |
| J_Opt_L_RabbitEar2_01 | 3 | −4.09 cm | −19.23 cm |
| J_Sec_L_SkirtBack1_01 | 4 | −3.93 cm | −8.32 cm |

Of the 37 springs that trail with the patch, upstream gives 0–66 % of that
response (the two bust springs 90 %). Three of them (`J_Sec_Hair1_06` and two
coat-skirt side springs) instead move forward slightly upstream (at most
0.3 cm).

**At rest with gravity, wind and colliders on** (`--natural`): upstream turns
`J_Sec_Hair1_06` and `_07` 135.4° and 134.1° away from the rest pose, and the
other hair strands do not droop at all (0.0°). With the patch the strands droop
6.6°–9.2° under gravity.

**Joints that are not direct children** (`AvatarSample_E-thinned`, 50
intermediate joints removed, 123 remain): upstream leaves 21 of 45 springs
completely still (e.g. `J_Sec_Hair1_10` 0.00 cm, `J_Opt_L_RabbitEar2_01`
0.00 cm); with the patch those move (−36.40 cm, −16.71 cm). The 8 springs that
stay still with the patch are the coat-skirt springs, which do not move in the
unthinned model either.

The same checks on Seed-san (freely downloadable) show the same pattern for
non-adjacent joints (`Seed-san-thinned`: tail 0.00 cm upstream, −13.53 cm with
the patch; axis differences 1.5°–65.1°, 146.2° on `hair_G.001`), but its
direct chains differ little (−14.46 vs −16.18 cm on the back hair).

At rest with gravity, wind and colliders off every joint stays within 0.01° of
the rest pose in both variants and on both models: a wrong axis does not show
at rest, because VRM4U derives both ends of its rotation from the same axis.

## Interpretation and limits

- 1–3 are reproduced on upstream master with a single sample model and fixed
  by the patches without changing Editor import or the rendered image.
- 4 is shown on a VRoid sample by the rest-skeleton angles, a response about
  weaker upstream (0–66 % on most springs), two hair strands turned ~135° at rest under gravity,
  and non-adjacent chains not moving at all. The cruise test moves the
  character in a straight line only; it did not reproduce hair moving the
  wrong way, which the shipping game reported during play.
- 1 and 2 were tested only on macOS. The UE 5.8 / Metal render-resource race
  that the shipping game also patches is not covered here (it needs two
  machines).
- Unreal MCP is enabled by the lab template (port 8101 here) but no run
  depends on it.
