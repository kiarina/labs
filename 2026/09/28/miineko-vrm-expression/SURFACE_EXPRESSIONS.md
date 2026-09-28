# Check expressions before polishing the mouth

## Current continuation

The owner selected the sticker sheet’s left-column, third-row smile as the
full-strength target. The short-line attempt was later corrected to keep the width and thickness of
its 92% state; [CRESCENT_SMILE.md](CRESCENT_SMILE.md) is the latest candidate;
this document retains the preceding shallow-arc and shading-control experiment.

## Priority and scope — 2026-09-29

The owner requested expression validation before mouth fine-tuning: the previous
smile revealed an undesirable bulb-like eye appearance and triggered a redesign.
Small-vowel response, audio timing and mouth contour polish are deferred until
this facial-expression direction is evaluated. [CONNECTED_VOWELS.md](CONNECTED_VOWELS.md)
remains the mouth reference, with its unresolved small-IH onset explicitly open.

Open `expression-study.html?variant=expressions&happy=1&opening=.6&angle=0`.
Smile, relaxed lids, closure, five mouth shapes and five angles can be combined.
**表情をゆっくり切替** cycles neutral, relaxed, blink, smile and neutral.
**通常顔に戻す** stops both previews and resets eyes and mouth. The selector also
retains the exact pre-expression model and a source-normal shading control.
This is a diagnostic expression prototype, **not an accepted finished face**.
Color patches and visible perimeter seams remain. Do not treat technical success
or reduced bulb shading as artistic acceptance.

## Questions and observations

Can the new shallow-eye surface support expression changes without adding the
old protruding lids? Does changing eye shading matter even when geometry is
identical? Can mouth shapes remain independent and the neutral face recover?

The first source-normal trial reproduced a strong eye disk and a raised-looking
highlight after closure. Normals inherited from the original eye sculpture were
therefore unsuitable for skin-colored eyelids. Fitting the lid normals from
surrounding pink skin substantially reduces this shading cue without moving the
head or the lid vertices. The control and candidate use the same geometry and
material parameters, differing only in the new lids' normals.

This is not proof that all unwanted volume comes from normals. The fixed eye
surface retains its geometry, and side views still expose perimeter artifacts.
The reconstructed skin color is smoother than the source texture and can read
as an oval patch. This remains a face-construction problem to address before
mouth/audio polish, rather than an acceptable finished result.

## Construction and runtime contract

The input is the current `mouth-connected-vowels` blend and VRM. Two transparent
layers per eye are clipped from its actual triangles, with a fixed forward
translation of .0007 (upper) and .0004 (lower) model units. No body coordinates or
source artwork are edited. Both layers are head-skinned. Eyelid color comes from
original pink texels or a distance-weighted estimate from 288 surrounding skin
samples per eye. The sampling does not invent source texture detail inside the eye.

A 2048-square procedural reveal texture and standard VRM texture-transform binds
move the lid edges. The upper edge carries the black line; the lower layer fills
behind it with a small overlap on closure. Smile changes the curvature through
U scale; blink is flatter; relaxation lowers only the upper lid. The added eyelids
have no morphs. The source normal control uses the original interpolated corner
normals; the candidate blends toward a local quadratic skin fit. Source body
normals are unchanged. This is stylized shading, not a reconstruction of hidden
anatomy. Both variants retain the previous mouth sampler and COLOR_0 mask patch.

The preview uses explicit normalized eye weights:

- happy = h * (1-b)
- relaxed = r * (1-h) * (1-b)
- blink = b

All preset overrides are `none`. A blink can thus fully close the half-open
relaxed pose. Mouth weighting remains independent. Other drivers must implement
this contract; the VRM does not normalize arbitrary inputs. Left/right blink
binds are exported and reimported but not separately exercised by this UI.

## Reproduce and evidence

Use the pinned environment and private inputs from [BASELINE.md](BASELINE.md),
then reproduce [CONNECTED_VOWELS.md](CONNECTED_VOWELS.md) first.

```sh
BLENDER_BIN=/path/to/Blender mise run surface-expressions-probe
```

The task replaces `artifacts/surface-expressions`, `-repeat` and `-source`.
Model, texture, screenshot and audit files remain private/ignored. The source
VRM's hash is checked against its generation report. Independent checks cover:

- [Geometry and import](results/surface-expressions-geometry.json): source body
  coordinates and five mouth binds are unchanged; parent-plane error is at most
  1.453e-8 model units; nearest surface distances are bounded by the fixed lid
  offsets. All five eye presets reimport with their expected texture bindings.
- [Runtime](results/surface-expressions-evaluation.json): zero-eye-state parity
  against the input for every vowel at five angles in both variants; intermediate
  and full expressions, mixed weights, a live cycle, reset, responsive layouts,
  and repeat-byte checks. These do not certify aesthetic quality, all poses or
  runtimes other than the tested three-vrm consumer.

The first geometry audit crossed nearly degenerate source triangles in float32,
producing a spurious plane error. The audit now computes its plane normals in
float64, as in the connected-mouth verifier. Factory-resetting Blender also
unloaded the VRM add-on; reimport clears scene objects while retaining the add-on.

## Next work

Evaluate expression silhouettes and the remaining lid-color/perimeter artifacts.
Keep the source-normal control so shading changes are compared independently
of geometry. If depth/boundary changes become necessary, preserve the existing
pink head and nose constraints and obtain a concrete scope decision for any
expansion beyond them. Mouth/audio fine-tuning remains deferred until this
expression structure is satisfactory. Full pose/skinning validation, gaze,
SpringBone, target-runtime checks and end-to-end rebuild still remain.
