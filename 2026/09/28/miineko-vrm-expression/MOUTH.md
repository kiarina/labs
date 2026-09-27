# Cartoon mouth opening on the selected face

## Aim and acceptance

The owner approved the flatter manga-like eyelids and relaxed expression in
`overlay-selected-plus`. The rounded eyelid comparison was rejected as too
realistic/scary for this mascot. This experiment adds only a small `aa` mouth
opening; it does not redesign the face or add realistic lips/teeth.

The first gate is exact restoration of the approved face at weight zero. Then
inspect low weights, half/full opening, both oblique/profile views, simultaneous
blink/relaxation, and attachment when the head turns. The original trial below covers `aa` only. The later reference-guided red mouth
and five-vowel experiments are recorded separately in [VOWELS.md](VOWELS.md);
artistic acceptance remains open.

## Rough-stamp reference follow-up

The owner supplied a private rough LINE-sticker sheet, then explicitly clarified
that it is an ideal reference rather than an absolute target. Use its economical
black contours, red mouth planes and graphic expressions as guidance, while
retaining the approved 3D character and sleepy-eye treatment. Do not turn exact
matching to the drawing into a new acceptance condition.

The controlled follow-up compares a larger red interior with the existing W rim
against the same interior plus local reduction of that rim's cross-section.
Only positive `aa` weights may thin the rim; Basis, the nose and the upper center
stem are pinned. The original selected input is preserved. The same neutral,
low-weight, side-view and eye-combination checks apply. This is an artistic and
geometric experiment, not evidence that a thinner outline is automatically better.

## Original small-opening construction

- Input: the preserved `artifacts/overlay-selected-plus/continuous-blink.blend`.
  The source VRM SHA-256 is
  `34f5456a9d9f4ec55c08bf34be70fc93c651e065f227cb5755e88c4f1e1876da`.
- Trace the original dark W-shaped smile through the source mesh's UVs; retain
  the original head, nose, mouth ridge, UVs, materials and eye bindings unchanged.
- Add a dark surface whose upper border stays under that smile and whose lower
  border grows down into a small rounded opening. At zero, every vertical strip
  collapses to a line and all its polygons have zero area. The new surface is
  weighted to the existing head bone.
- Bind a normal, nonbinary VRM `aa` expression to the new mesh's `AA` morph.
  This is a cartoon depiction of an opening, not a topological hole through the
  source head or an anatomical mouth cavity.
- An optional second collapsed mesh adds a flat pink accent inside the opening.
  It shares the same `aa` expression. There are no teeth or anatomical tongue
  details. The source shape is not altered in either variant.

`scripts/mouth_aa_probe.py` saves the sampled curve and parameters in ignored
artifact reports. The nominal half-width is 0.076 m and the opening's lower-center
height is 0.423 m in this approximately one-meter character's source coordinates.
These are input-specific authoring values, not transferable human anatomy rules.

## Trials and observations (2026-09-28)

| Artifact directory | Observation |
| --- | --- |
| `mouth-aa-cartoon` | Collapsing onto the center of the old black ridge hid most changes until larger weights. Preserved the source at zero, but onset was too weak. Kept as a failed comparison. |
| `mouth-aa-onset` | Collapsing at the lower dark rim makes the opening respond earlier. Simple dark mouth; source W smile remains the upper edge. Current plain prototype. |
| `mouth-aa-tongue` | Same motion with a small flat pink accent. An optional appearance comparison, not a confirmed owner choice. |

Both current prototypes were checked with five viewing angles (front, ±45°,
±90°) at `aa=0, .02, .05, .10, .25, .50, .75, 1`: 40 captures each. Six additional
front captures combine `aa=.5/1`, relaxed `.35`, and blink `0/.5/1`.

- All source Body vertex coordinates remain unchanged in the builder.
- Across 20 zero-mouth cases (five views × two relaxed values × two blink values),
  the full rendered image exactly matched `overlay-selected-plus` in the tested
  three-vrm runtime. Nose, smile and approved eyes are therefore restored in
  those cases. The earlier 36 relaxed/blink composition checks also still pass.
- The pink variant was inspected with head yaw -0.35, 0 and +0.35 radians; the
  added mouth meshes follow the head. This is a limited attachment check, not a
  complete animation/motion-capture validation.
- The corrected onset grows monotonically in the sampled front renders. In the
  fixed mouth region, dark-pixel counts at weights `0/.1/.25/.5/.75/1` were
  `4018/4030/4254/4696/5133/5659`; the first trial gave
  `4018/4019/4022/4431/5028/5659`. This measures visible response, not aesthetic
  quality. At `.02/.05`, the small change remains hidden by the original ridge
  at the tested full-face resolution.
- The opening stays attached in the inspected oblique/profile images. It is
  deliberately shallow; it should not be described as a reconstructed cavity.
- No runtime errors/warnings were reported. Blender reimport retains `aa`,
  the approved eye bindings, and `relaxed.overrideBlink=blend`.
- Rebuilding the corrected plain prototype from the same input produced an
  identical VRM binary. Original approved artifacts were not overwritten.

The dark/pink materials are emitted by the exporter as standard glTF materials
with black base color and an emissive color. Do not claim `KHR_materials_unlit`
was emitted. The tests use Blender 5.1.2, VRM Add-on 4.7.2, three 0.186.1 and
three-vrm 3.5.5; other VRM importers have not been verified for this collapsed
neutral topology. Explicit per-vertex lip motion and other vowel presets remain
outside this trial.

## Reproduce

Numerical evidence is stored in
[results/cartoon-mouth-evaluation.json](results/cartoon-mouth-evaluation.json).

Prepare the approved input using the previous `overlay-followup` task. Use the
same `BLENDER_BIN`, `COMPARE_PYTHON` and optional `CHROME_BIN` environment as in
[EXPERIMENTS.md](EXPERIMENTS.md). The new task builds, captures actual VRM states
in the independent viewer, and checks Blender binding reimport:

```sh
mise run mouth-probe
MOUTH_RUN=mouth-aa-tongue MOUTH_TONGUE=1 mise run mouth-probe
```

Open `viewer.html?model=mouth-aa-onset` or `viewer.html?model=mouth-aa-tongue` on
the local server. `口を開く` controls the actual `aa` expression and can be used
with relaxed eyes and automatic blink. `MOUTH_TONGUE=1` defaults to the separate
`mouth-aa-tongue` directory, preserving the plain comparison. The builder refuses
the two owner-selected input directories. All images/models remain private in
ignored `artifacts/`; scripts and numerical evidence are versioned.
