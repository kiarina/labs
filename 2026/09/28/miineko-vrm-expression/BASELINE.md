# Earlier accepted expression baseline

## Current design direction

The current working baseline is the provisionally accepted mouth-plus-ear surprise
in [SURPRISE_EARS.md](SURPRISE_EARS.md); [README.md](README.md) summarizes all
current expression decisions. This document owns the earlier `mouth-aa-aligned`
input chain and tool pins. Its owner acceptance and measurements below belong to
that earlier stage; they do not require preserving the rejected protruding eyes
or mouth in the current face. The new source chain continues from this baseline.

## Scope and acceptance

As of 2026-09-28, the owner accepts `mouth-aa-aligned`: the original Tripo head,
manga-like eyelid overlay, relaxed eyes and five cartoon mouth shapes. Rounded,
more realistic eyelid corners were rejected for this mascot. The rough sticker
sheet is artistic guidance, not an exact-match target. Owner preference is part
of the quality criterion; low pixel error or anatomical realism alone is not.

- Final file: `artifacts/mouth-aa-aligned/continuous-blink.vrm`.
- SHA-256: `cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31`.
- Eye-only references: `continuous-fresh` (selection-time appearance) and
  `overlay-selected-plus` (same eyes with relaxation).
- Editable scenes, original inputs and rendered comparisons remain in ignored
  local storage. Git alone does not contain the character or a ready-to-open VRM.

Keep the accepted files as comparison inputs. Some task defaults overwrite their
named output directories; source-directory guards are not a universal freeze.
Use a separate workspace for a full rebuild, and new `MOUTH_RUN` names for later
experiments. The suffix `continuous-blink` is retained in mouth-stage filenames;
it does not mean the VRM contains only blinking.

## Inputs and tested tools

The private source is the Tripo Multi-view → H3.1 HD Model → Quad Smart Mesh
Retopo (10,000 target) → VRM 1.0 Humanoid FBX and accompanying textures. It is
owned by `kiarina/assets`, under `miineko/tripo/v1/` (source commit `280b18f`).
FBX SHA-256: `1902b3712bc8de441ade04ff951123e65bd5b8d243c498fdb3bf433dfa53297b`.

Tested on macOS arm64: Blender 5.1.2, VRM Add-on 4.7.2, Python 3.13.12,
NumPy 2.4.3, Pillow 11.3.0, Node 22.22.0, three 0.186.1, three-vrm 3.5.5,
puppeteer-core 25.12.0. Browser tests launch installed Chrome (`CHROME_BIN` can
override its path); the viewport is 900×1000, with a canvas below the controls.
Historical Blender renders use their own recorded scene/sampling settings.

These are controlled comparison pins, not claims of newest releases. The
2026-09-28 repository maintenance review left the Pillow update deferred by the
owner while this experiment was active. This was reconsidered for the next
motion stage: the prior trial matched 19/20 output files, but changed historical
atlas PNG bytes despite equal pixels. Keep the frozen comparison pin; the
JavaScript-only motion stage does not run Pillow. Retain measured dependencies
until migration/parity is resolved; under the labs policy, a non-byte-identical migration needs a separate
lab/baseline. Do not silently update dependencies and attribute changed output
to geometry. The manifest and lockfile agree on the viewer versions above.

## Rebuild order

Use a separate workspace with the same scripts and private input. Start with a
fresh shell: only export the path variables below, not previous experiment's
`BLINK_*`, `MOUTH_*`, `VOWEL_*` or `PROBE_*` overrides. Install the compatible VRM
add-on in the selected Blender first. No task installs it or obtains the FBX.

```sh
export MIINEKO_FBX=/path/to/original-tripo.fbx
export BLENDER_BIN=/path/to/Blender
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-compare.txt
export COMPARE_PYTHON="$PWD/.venv/bin/python"
# export CHROME_BIN=/path/to/Chrome  # if the default path does not apply
npm ci

BLINK_RUN=continuous-fresh mise run continuous-probe
mise run overlay-followup
MOUTH_FLAT_START=1 mise run vowel-probe
mise run mouth-profile-probe
MOUTH_ONSET_DEPTH=lip-occlusion mise run mouth-profile-probe
mise run full-vowel-probe
mise run align-aa-probe
```

| Stage | Output/dependency reason |
| --- | --- |
| `continuous-probe` | Imports the FBX, corrects the short-leg rest bones, and creates `base-vrm`, the comparison studio, and `continuous-fresh`. The explicit run name is required by later tasks. |
| `overlay-followup` | Creates `overlay-selected-plus`, adding relaxed/blink composition. |
| `vowel-probe` with flat start | Creates `mouth-red-bound` input and `mouth-vowels-flatstart`, including baseline screenshots used by depth comparisons. |
| `mouth-profile-probe` | Creates `mouth-profile-fitted` and its full-target reference captures. |
| Same task with lip occlusion | Creates `mouth-onset-recessed`; the preceding profile files are needed for its comparison gate. |
| `full-vowel-probe` | Creates `mouth-full-refined`, preserving AA while changing IH/OU/EE/OH. |
| `align-aa-probe` | Creates `mouth-aa-aligned`, preserving the four approved vowels while changing AA. |

The order is traced from the current task scripts. Stages have been executed and
their local repeats measured; the eye stage was also repeated from the original
FBX. A fresh, entire FBX-to-final-mouth run has not been repeated in one invocation
after the final AA change. Do not overstate the final-stage repeat as that test.
All commands are local; they do not generate new images through an API or consume
Tripo credits. Some comparisons require prior screenshots as well as blends.

To repeat only the final stage without replacing the accepted file:

```sh
MOUTH_RUN=mouth-aa-repeat mise run align-aa-probe
cmp artifacts/mouth-aa-aligned/continuous-blink.vrm artifacts/mouth-aa-repeat/continuous-blink.vrm
```

For interactive inspection, serve this lab on loopback with
`python3 -m http.server 52714 --bind 127.0.0.1` and open
`http://127.0.0.1:52714/viewer.html?model=mouth-aa-aligned`.
The comparison controls drive exported VRM expressions. Natural blink timing is
a viewer demonstration, not a self-playing animation embedded in the VRM.

## Lessons that define the current method

1. Preserve the original head, UVs and source appearance. Whole-head replacement
   and a rebaked full-face shell lost the character's look. The original UV is
   scattered, so applying one texture offset to the original body material also
   moves unrelated regions. Keep independently controlled surfaces/materials.
2. Two unrelated atlas tiles do not interpolate into a half blink. The chosen
   eyes use continuous alpha coverage plus local source-eye clearance. Relaxation
   uses `overrideBlink=blend`; the checked combination is `r + (1-r)*blink`.
3. A collapsed W-shaped neutral mouth leaves a central peak during linear opening.
   The accepted mouth instead starts as a shallow, nondegenerate surface hidden
   by zero alpha, with a horizontal reveal and flat central floor. Do not apply
   the old zero-area-neutral test to it; check neutral texture alpha and renders.
4. One RGBA palette/reveal texture on a standard unlit surface avoids separate
   red/black layers intersecting in blends. Blender node wiring alone is not
   proof of export: alpha-only unlit wiring dropped the texture, and an attempted
   multiply put useful colors in `COLOR_1` while the viewer used white `COLOR_0`.
   Inspect the exported material, texture and attributes in the actual runtime.
5. The mouth texture needs its dedicated, non-mipmapped glTF LINEAR sampler.
   Mipmaps leaked a few neutral pixels at narrow corners. Builders apply this
   after export. A manual Blender re-export may restore default mipmaps, so it
   must be patched/rechecked before being treated as the accepted result.
6. Fit depth for intermediate states and triangle interiors, not only vertices
   or endpoints. Preserve collapsed unused columns in all coordinates to avoid
   colored shelves. Source black lip ink is allowed to occlude the red mouth;
   requiring the mouth to cover the raised black ridge made it protrude. Pink-face
   penetration and intentional black-lip occlusion are measured separately.
7. Drivers must keep vowel weights nonnegative with sum ≤1. This is this
   method's driving contract, not something VRM automatically enforces. More
   accurate geometry does not imply better mascot art direction.

## What the evidence does and does not establish

The accepted file has nonempty bindings for blink/left/right, relaxed and the
five vowels. Other preset names exist but are not evidence of working emotions
or gaze. The final file currently has no `VRMC_springBone` extension; spring
motion in the rejected early model does not validate this route.

The final-stage record is
[aa-depth-alignment-evaluation.json](results/aa-depth-alignment-evaluation.json):
20 closed-mouth cases, six eye-region cases and 36 relaxed/blink cases match their
references; the four preserved vowels match in 120 views. The final VRM repeats
byte-identically. Surface constraints are sampled and tied to this input's UV
ink classification. They do not prove collision freedom for all poses/weights.
Blender reimport checks bindings, not round-trip shading. Pixel differences and
owner approval are distinct kinds of evidence; neither replaces the other.
Older machine reports can contain `visualAcceptance: not granted`; they do not
track subsequent owner decisions. Preserve those records; this document records
the earlier acceptance, and [README.md](README.md) owns the current status.

## Handoff and remaining work

A [silent playback preview](MOTION.md) now checks fades, pauses and normalized
mixtures without modifying this baseline. An [audio-backed vowel test](AUDIO.md)
now checks known cues and media-clock playback. A [continuous greeting](SPEECH.md)
adds authored approximate timing and transitions; the owner found it natural.
The [happy-eye prototype](HAPPY.md) was rejected for its raised-eye appearance.
The revised face continues through [SURPRISE_EARS.md](SURPRISE_EARS.md);
use its input chain before rebuilding expressions.
automatic phoneme alignment remains open. Gaze and ear/tail springs need integration and
combined runtime validation. Do not automatically return to rejected realistic
eyelids or full-head replacement. Another character requires its own calibration.

Export metadata is still experimental: the current file declares `onlyAuthor`,
`personalNonProfit`, `allowRedistribution=false`, `modification=prohibited` and
required credits. These settings came from `setup_vrm_base.py`; they are not a
record of the owner's final distribution decision. Review them with the owner
before any public or product distribution. No character asset is published here.
