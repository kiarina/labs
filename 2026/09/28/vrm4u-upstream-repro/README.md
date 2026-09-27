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

The axis VRM4U uses differs from the specification's on every Seed-san joint:
1.5°–65.1°, and 146.2° on `hair_G.001`
([`results/spring-axis-Seed-san.txt`](results/spring-axis-Seed-san.txt)).

| Model | Spring | Joints | Tail offset, upstream (00+02) | Tail offset, 00+02+04 |
|---|---|---|---|---|
| Seed-san | hair_tail_1 | 7 | −14.46 cm | −16.18 cm |
| Seed-san | robo_wire | 7 | −36.96 cm | −38.40 cm |
| Seed-san | hair_A_001 | 2 | −2.33 cm | −2.51 cm |
| Seed-san-thinned | hair_tail_1 | 4 | 0.00 cm | −13.53 cm |
| Seed-san-thinned | robo_wire | 4 | 0.00 cm | −29.20 cm |

- When the Tail is not the Head's direct child, upstream leaves the chain
  where it is: each joint's position comes from the incoming pose and plain
  nodes are never output, so the tail does not move at all. The patch composes
  the rest transform across the plain nodes and moves them rigidly with the
  joint.
- Direct parent–child chains respond similarly before and after.
- At rest (no gravity, wind or colliders) every joint stays within 0.01° of
  the authored rest pose in both variants. A wrong axis does not show at rest:
  VRM4U derives both ends of its rotation from the same axis, so they cancel.

## Interpretation and limits

- 1–3 are reproduced on upstream master with a single sample model and fixed
  by the patches without changing Editor import or the rendered image.
- 4 is shown by the specification and the rest-skeleton angles, and by the
  non-adjacent chains not moving at all. The lab does not measure a "wrong
  direction" of motion on direct chains; with gravity and colliders off the
  direct-chain differences are small. The shipping game saw hair on a VRoid
  VRM 1.0 model react against the character's motion; that model is private
  and is not part of this lab.
- 1 and 2 were tested only on macOS. The UE 5.8 / Metal render-resource race
  that the shipping game also patches is not covered here (it needs two
  machines).
- Unreal MCP is enabled by the lab template (port 8101 here) but no run
  depends on it.
