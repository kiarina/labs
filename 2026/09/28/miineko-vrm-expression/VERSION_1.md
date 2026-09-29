# Miineko version 1 — fixed checkpoint

## Identity and status — 2026-09-29

The owner accepted `lid-envelope` and fixed it as **version 1**. This is the saved
checkpoint for subsequent use and comparison, not a request to keep refining the
same files in place. The accepted output includes the earlier highlight and
closed-lid color repairs. Those changes are no longer pending candidate review.

Private distribution files are `miineko/vrm/miineko.blend` and `miineko/vrm/miineko.vrm`
in the assets repository. They are byte-identical copies of this lab's
`artifacts/lid-envelope/continuous-blink.{blend,vrm}`. The assets repository keeps
only the current finished files and overwrites them when the owner fixes a new
version, so this file owns the hashes and lineage below. The earlier
`miineko/tripo/v1/miineko-blink-aligned.*` files remain historical checkpoints in
the assets history (commit `6d75075`), not current delivery paths.

| Artifact | SHA-256 |
| --- | --- |
| Runtime VRM | `837063759099210436b9c23dbf8aa61aa56f26febfa7224ec563d61a7ce64cb8` |
| Authoring blend | `d11f1d2fe3943e97002ba8720ed85f36dd61a9725fbc4d6f88d97d5df4cd9b7e` |

Implementation checkpoint: `a720b85`. All 11 file-backed images in the copied
blend are packed, and it opens from the new location. Packed images retain old
path strings; these are not missing-file dependencies for displaying this copy.
This checkpoint label does not change the embedded VRM metadata or license fields.

## Included behavior and driver contract

- Original pink head shape and nose retained; black eye/W/stem depth refined.
  Original W/stem stroke weight is retained.
- Five connected vowel shapes on a fixed surface, with independent mouth control.
- Happy, angry, sad, relaxed, ordinary and unilateral blink; shared-onset,
  approximately 7:3 upper/lower closure with the original highlight occluded.
- Surprise keeps normal round eyes and raises the ears through a morph target.
  The `surprised` preset is **ears only**; the example OH mouth is driven separately.
- Highlight-normal, closed-lid color and oblique-coverage fixes are included.

The current viewer normalizes happy/angry/sad together and attenuates them by
blink. Relaxed uses the remaining eye contribution. Ear surprise is independent
of that normalization and of blink. Vowel weights are nonnegative and normalized
to sum at most one. Other consumers must apply the same driving contract; VRM
loading alone does not guarantee these mixtures. The preview's `early` mouth
response q^.6 is viewer logic, not a different baked vowel curve.

Review using `expression-study.html?variant=lid-envelope&opening=0&blink=0`.

## Source chain and reproduction

Start with the private input and pinned toolchain in [BASELINE.md](BASELINE.md).
The data lineage is:

`mouth-aa-aligned → feature-eyes → feature-mouth-flush → mouth-connected-vowels
→ sync-smile → eye-emotions → eye-emotions-steeper → surprise-ears → blink-aligned
→ highlight-clean-r → lid-rim-clean → lid-envelope`.

Use the staged route through `surprise-ears` in [SURPRISE_EARS.md](SURPRISE_EARS.md),
then the tasks in [BLINK_ALIGNED.md](BLINK_ALIGNED.md),
[HIGHLIGHT_CLEAN.md](HIGHLIGHT_CLEAN.md), [LID_RIM_CLEAN.md](LID_RIM_CLEAN.md), and
[LID_ENVELOPE.md](LID_ENVELOPE.md). The steeper-sad audit additionally needs the
straight-sad comparison output; that comparison is not its builder's data input.
Rejected `thin-*`, `happy-arc`, and `surprise-eyes` models are not final inputs.

Stage-by-stage repeatability has been checked; a fresh FBX-to-final run in one
clean workspace has **not**. Build in a separate workspace/output area because
some task defaults overwrite their named artifacts. The runtime GLB includes
explicit export patches and later accessor/preset edits. A plain GUI export of
the blend is not the validated runtime output. Do not silently replace version 1
with such an export, a dependency update, or an unreviewed refinement.

## Lessons retained from the final cleanup

| Symptom | Isolated cause / useful distinction | Focused correction |
| --- | --- | --- |
| Dark mark inside the white highlight | Unlit rendering removed it; normal-map disabling alone did not. Normal-only repair isolated a vertex-normal contribution. | Local normal fit; original image and circle geometry retained. [Evidence](HIGHLIGHT_CLEAN.md) |
| Circular flecks around closed eyes | Marks remained through lighting/depth diagnostics but disappeared when lid vertex RGB was replaced. | Reconstruct clean skin color on lids; preserve alpha, geometry and black line. [Evidence](LID_RIM_CLEAN.md) |
| White/black slivers from oblique views | Original eye facets could lie ahead of a translated copy used as a lid. More opacity or uniform inflation did not solve it. | Fit lids to the foremost surface with a small conservative neighborhood. [Evidence](LID_ENVELOPE.md) |

Appearance, artistic acceptance, file/data invariants and runtime compatibility
are separate evidence. Keep camera/lighting/viewport fixed for image comparisons;
record numerical tolerances and failed approaches rather than treating all
similar-looking marks as one cause. Color/normal corrections are model-specific.

## Verification boundary and post-v1 work

The final lid stage has 13-angle expression checks, exact frontal closed-line
masks, repeated VRM bytes and saved-blend/runtime position agreement. Minor
neutral-view coverage differences at some oblique angles remain documented.
The latest full-body dance/joint test used the earlier `blink-aligned` model;
**the final depth-refitted lids have not been rechecked under that full-body test**.

Known follow-ups belong to a later revision or integration task:

- Blend the remaining skin-color/material transitions; any further eye ratios
  or timing changes should compare against this fixed version.
- Revisit ribbon folding and arm/head interference found in [BODY_MOTION.md](BODY_MOTION.md).
  Adapt motion to the mascot's proportions instead of assuming all problems are weights.
- Integrate audio with this face and refine small vowel openings. Natural greeting
  feedback applies to the older `mouth-aa-aligned` model with authored timing;
  arbitrary speech-to-vowel inference is not implemented.
- Add/validate gaze, ear/tail spring behavior, full-body poses, and the intended
  target runtime. Raised-ear morphs are not ear bones or SpringBone.
- Verify a fresh complete regeneration and review experimental distribution
  metadata when actual distribution/use requires it.

Freezing version 1 is a concrete accepted milestone, not a claim that these
remaining items are complete. Preserve the checkpoint and branch experiments by
output name until the owner chooses a replacement version.
