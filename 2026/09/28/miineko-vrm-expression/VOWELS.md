# Five cartoon mouth shapes from a rough expression reference

## Aim

Use the owner's private rough sticker sheet as expression guidance, not an exact
target. Keep the approved manga-like eyes, source nose and W smile. Test a red
graphic opening and five distinguishable vowel targets without replacing the
head. These are authoring prototypes; audio-driven lip sync and artistic
acceptance are not established by the presence of five VRM presets.

## Construction and failed comparisons

**Current follow-up:** after viewing `mouth-vowels-stable`, the owner supported
the direction but reported that the lower edge retained a central W-shaped peak
while opening (screenshot at approximately 22%). `mouth-vowels-flatstart` is the
new comparison candidate; the earlier build remains available. See the flat
onset section below. The earlier construction and measurements in this document
describe `mouth-vowels-stable`, not the revised invisible neutral surface.

The input is the preserved `overlay-selected-plus` blend. The first stage
(`scripts/mouth_aa_probe.py`) traces the W rim and builds a collapsed-neutral
opening, as described in [MOUTH.md](MOUTH.md). The follow-up uses a lower center
height of 0.415 m and a larger red fill.

| Artifact | Observation |
| --- | --- |
| `mouth-red-panel` / `mouth-red-light` | Larger red fill, respectively original rim or locally thinned rim. Separate red and black surfaces intersect and produce small black artifacts. Thinning can sharpen the corners; it is not an adopted improvement. |
| `mouth-red-bound` / `mouth-red-bound-light` | Red fill follows the actual opening triangles. Cleaner single target, but the later vowel mixtures can still intersect. Only the `light` comparison moves source Body vertices while opening; Basis and nose/eye regions are pinned. |
| `mouth-red-vowels` | Five shapes with fixed X columns; narrow shapes collapse the unused columns. Two separate colored surfaces still cause artifacts in blends. |
| `mouth-vowels-flat` | One mouth surface with red/black vertex colors removes red/black intersection. Interpolated shapes can still cut through the curved original face. |
| `mouth-vowels-envelope` | Per-column affine depth support clears the sampled face for morph mixtures, but the broad sampling range unnecessarily projects some edges forward. |
| `mouth-vowels-stable` | The same support restricted to each column's actual morph range. Earlier inspectable prototype. Front/oblique mixtures are cleaner; a thin projecting edge remains visible in profile. |

The final stage (`scripts/add_vowel_shapes.py`) keeps source Body and eyes intact.
Each vertical mouth column has one fixed X and an affine depth `y = a + b*z`.
The coefficients are fit in front of 241 source-face samples per column, over
that column's actual range across Basis and all target vertices. Consequently,
normalized linear mixtures share that support field rather than connecting
different curved surfaces through the head. This is a sampled clearance method,
not a proof of collision freedom for every triangle or pose.

The final single mesh has 2,737 vertices and 5,120 exported triangles, weighted
only to the existing head bone. Its neutral triangles all have zero area. Red
and black are vertex colors on one standard `KHR_materials_unlit` material;
they do not need custom code or layered depth offsets in the viewer.

| VRM preset | Half-width (m) | Lower-center Z (m) |
| --- | ---: | ---: |
| aa | .076 | .415 |
| ih | .076 | .442 |
| ou | .038 | .421 |
| ee | .068 | .432 |
| oh | .048 | .404 |

These dimensions are fitted to this roughly one-meter character, not a general
vowel anatomy rule. A future speech driver must use nonnegative weights whose
sum is at most one. VRM itself does not impose this normalization.

## Observations (2026-09-28)

Tested with Blender 5.1.2 / VRM Add-on 4.7.2 and an independent three 0.186.1 /
three-vrm 3.5.5 viewer on Apple Silicon macOS. Numerical records are in
[results/reference-mouth-evaluation.json](results/reference-mouth-evaluation.json).

- All 20 closed-mouth comparisons exactly match the approved input (five views,
  two relaxation values, two blink values). Twelve additional comparisons show
  each other vowel's zero value exactly matches `aa=0` at front and ±45 degrees.
- The existing 36 relaxed/blink composition cases remain pixel-identical.
  Six `aa=0` versus `aa=1` comparisons also preserve the top 65% of the front
  frame exactly, covering the eyes, forehead and upper nose.
- Captured 40 `aa` states (eight weights and five views), 45 vowel states (five
  vowels, three weights, three views), and six normalized blend examples (three
  mixtures, front and +45 degrees). The five fully open front shapes are
  numerically distinct; this does not certify phonetic clarity.
- Head yaw at -0.35, 0 and +0.35 radians keeps the mouth attached. This is a
  limited skinning check, not validation of all animation or retargeting.
- Blender reimport retains all five nonbinary mouth bindings, blink variants,
  and relaxed override behavior. The reimport check verifies bindings only,
  not round-trip shading. The final material is visually checked in three-vrm.
- Rebuilding both mouth stages from the preserved approved blend in separate
  directories produced byte-identical red-input and final VRM files. The final
  SHA-256 is `e5255d9f274283b4081a7c152c2abe137b2819c1dce458c047777abd64e16769`.
  The five UI selections set only the selected preset's weight; automatic blink,
  original-model toggle and 600-pixel-wide layout checks pass without console
  errors or warnings.
- Sampled support clearance is at least 1 mm; maximum sampled forward distance
  is 16.32 mm, down from 19.60 mm in the broad-range trial. This is **not** a
  claim of a 1 mm conformal shell. The side-view projection remains a drawback.

The red opening is deliberately a cartoon surface, not a cavity. The fixed W
rim means the narrow shapes can read as a tongue rather than rounded human lips.
At very low weights the red response is slight, and some of the existing black
rim is covered as the opening grows. The neutral face is preserved exactly, but
that alone does not prove the opened mouth is artistically finished. Further
work should evaluate motion/timing and side-view attachment before expanding
the remaining emotion set. Other importers and audio synchronization are untested.

## Reproduce and inspect

Prepare `overlay-selected-plus` with `mise run overlay-followup`. Set
`BLENDER_BIN`, `COMPARE_PYTHON` (Python with NumPy and Pillow), and optionally
`CHROME_BIN` as described in [EXPERIMENTS.md](EXPERIMENTS.md). Then run:

```sh
mise run vowel-probe
# Independent output directories for a complete mouth-stage repeat:
MOUTH_RUN=mouth-vowels-repeat VOWEL_INPUT=mouth-red-repeat mise run vowel-probe
```

The task rebuilds the red input, adds the single-surface vowel targets, verifies
the actual VRM in the independent viewer, reimports it into Blender, and measures
the screenshots. It preserves the owner-approved input directories. All models,
input references and screenshots stay in ignored `artifacts/`; only scripts,
parameters and numerical records are versioned.

Open `viewer.html?model=mouth-vowels-stable` on the local server. `口の形` selects
the vowel and `口を開く` controls its weight. The eye, relaxation, angle and
automatic blink controls remain available. The dropdown also retains previous
mouth candidates and the unmodified approved face for comparison.

The owner subsequently approved the improved front appearance. The next
depth-only comparison and its remaining profile defects are in [PROFILE.md](PROFILE.md).

## Flat onset follow-up (2026-09-28)

A linear morph from a collapsed W contour retains some of its central peak at
intermediate weights. The revised candidate instead has a shallow, invisible
neutral mouth with a nearly flat central floor. Its floor profile uses a fourth
power rather than a quadratic, so its central section remains flatter as it
opens. The lower-center heights for `ih` and `ee` are .435 and .428 m; the other
three full-open heights are unchanged. This alters both onset and full-open
floor curvature; it is not just a timing change in the viewer.

The extra neutral surface is hidden by zero texture alpha. During the first
12% of the normalized mouth weight, a horizontal alpha boundary reveals it
progressively; the morph simultaneously lowers the floor. The upper W smile and
source Body remain in place. All five presets contain their morph and the same
standard VRM TextureTransformBind, so normalized mixtures move the reveal by
the sum of their weights. This still requires nonnegative weights totaling at
most one. Very small openings first reveal a small central red area; motion
still needs artistic evaluation and audio calibration.

The material is standard glTF unlit with one RGBA texture. U stores the static
red/black palette; V stores reveal progress. An alpha-only texture connection
was omitted by Blender's unlit exporter, and a texture/vertex-color multiply
exported the useful colors as COLOR_1 while the viewer used white COLOR_0.
Encoding both palette and alpha in one texture avoids these exporter issues.
The procedural palette explicitly encodes its linear RGB values as sRGB.

The final export step gives this texture a dedicated non-mipmapped LINEAR glTF
sampler. The exporter's default mipmaps caused a few neutral pixels to remain
visible at thin corners, despite zero alpha at the base UVs. This is a standard
sampler setting in the saved VRM, not a viewer-specific patch. Re-exporting the
blend manually needs the same sampler adjustment; use the generation script
for the verified result. Blender reimport checks bindings, not shading parity.

Neutral triangles now have nonzero area: the correct structural test is zero
alpha across the neutral UV rectangle (with a filtering margin), followed by
render comparison with the approved face. Do not reuse the earlier zero-area
assertion for this variant. Floor checks compare the center against both
nearby flanks at six weights for all five targets. Runtime captures now include
22% explicitly, with 45 aa captures and 75 vowel captures plus mixtures.
All 20 neutral comparisons, 36 relaxed/blink comparisons and six eye-region
checks are pixel-identical; 30 floor checks show no raised center at the tested
weights. Five-vowel binding reimport and a separate deterministic rebuild pass.
Evidence: [results/flat-mouth-onset-evaluation.json](results/flat-mouth-onset-evaluation.json).

Reproduce while preserving the earlier candidate:

```sh
MOUTH_FLAT_START=1 mise run vowel-probe
```

To rebuild only this follow-up from the existing `mouth-red-bound` input:

```sh
MOUTH_RUN=mouth-vowels-flatstart MOUTH_SINGLE_SURFACE=1 \
MOUTH_ENVELOPE=linear-local MOUTH_FLAT_START=1 \
"$BLENDER_BIN" --background --python-exit-code 1 --python scripts/add_vowel_shapes.py
```

Open `viewer.html?model=mouth-vowels-flatstart`. The previous opening is available
as a separate comparison. The profile projection remains a limitation: the new
sampled maximum support distance is 18.38 mm. This change targets the center
peak, not the separate problem of a shallow mouth surface projecting in profile.
