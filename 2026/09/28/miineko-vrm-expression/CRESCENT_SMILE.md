# Preserve the eye width and thickness of the former 92% smile

## Owner correction — 2026-09-29

The owner found [ROUNDED_SMILE.md](ROUNDED_SMILE.md)'s 100% endpoint too thin, with
ends that did not fit the original eye size. The supplied **92% screenshot** was
closer to the sticker reference in shape, despite its remaining white highlight
and superimposed upper arc. The current target is therefore the broad remaining
eye shape at that intermediate state, cleaned up into a single black smile.
Do not reinterpret this as another request for a shorter, thinner drawn line.

Open `expression-study.html?variant=crescent&happy=1&opening=0&angle=0`.
The old `rounded` variant is preserved; set its happiness to .92 to compare the
specified reference. The new model is a candidate, not owner-approved. Head,
nose, original mouth width and five vowels remain unchanged. The pre-existing
skin-color patch and jagged lid perimeter remain unresolved.

## Construction

The new `happy=1` applies **.92 of the old rounded happy transform** to the pink
upper/lower layers: depth shifts multiply by .92; U scale changes from
`1 + (5.5 - 1) * .92 = 5.14`. Thus the upper edge is
`z=.65672-.1056784*(x/.104)^2`, and the lower edge is
`z=.63308-.1056784*(x/.104)^2`. Their gap keeps a substantial black band rather
than closing to the previous narrow added stroke. The original eye determines
its outer ends. This is a model-level endpoint, not just a viewer slider cap.

The separate upper ink layer receives no happy transform, so the extra small
arc stays invisible during a pure smile. It remains available for blink and
relaxed expressions. Two new black fills follow the same source triangles,
.0002 model units in front of the eye and behind both lids. Their vertex-alpha
mask covers the original eye artwork, including its white highlight, while
suppressing the fill at vertices classified as surrounding pink skin. Standard happy material-color binds increase
fill alpha from zero to one. At full happiness the visible band is uniformly
black; at intermediate values the highlight fades gradually.

The fill uses standard glTF unlit shading. Export postprocessing explicitly
sets its base-color factor to `[1,1,1,0]`, `alphaMode=BLEND` and the unlit
extension, retaining the black vertex RGB and static mask. Source colors and
geometry are not rewritten. Direct GUI re-export without this patch is not the
validated artifact. No custom browser shader or per-frame geometry edit is used.

The existing normalized eye-weight contract remains in place; mouth control is
independent. Full blink and relaxed expressions are unchanged from the preceding
rounded model when happy is zero, subject to the same existing boundary issues.
The older variants and their model bytes remain separate reference artifacts.

## Reproduce and validation

Use the pinned environment and input chain in [BASELINE.md](BASELINE.md),
[CONNECTED_VOWELS.md](CONNECTED_VOWELS.md) and [ROUNDED_SMILE.md](ROUNDED_SMILE.md).

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run crescent-smile-probe
```

This writes `artifacts/crescent-smile`, `-repeat`, and captures under
`artifacts/crescent-smile-review`. Private bitmaps, models and audit arrays stay
ignored. The source hash is checked against its build report.

The experiment checks the requested corrections rather than treating successful
export as good appearance:

- [Silhouette report](results/crescent-smile-silhouette.json): compare new 100%
  against old 92% and old 100% at a fixed front view. Check eye width, visible
  band area, absence of bright white pixels, and lower-edge pixel agreement.
  Require one substantial dark component in each new eye, removing the doubled
  arc from the endpoint. This is not a claim about every camera angle.
- [Geometry/import report](results/crescent-smile-geometry.json): source body and
  five mouth binds unchanged; all lid/fill planes remain near their source
  triangles. Six texture binds per bilateral eye expression and two happy color
  binds reimport. The added fill remains transparent at neutral.
- [Runtime report](results/crescent-smile-evaluation.json): zero-eye parity for
  five vowels × five views in new/old variants; five strengths of three expressions
  at five angles in both models (150 captures); mixed weights, live transition,
  reset, three screen widths, and repeat-byte equality.

## Measured endpoint

At the fixed frontal resolution, new eye widths are 178/179 px, matching the
former 92% sample (the rejected thin 100% arcs were 120 px). New black areas
are 4,602/4,638 pixels versus 1,216/1,220 for the thin arcs. Bright-white counts
drop from 1,361/1,315 in the 92% reference to zero in the new full smile.

The lid transforms match the old .92 values numerically. A strict whole-edge
pixel comparison initially failed at a few outermost columns: max differences
were 5/6 pixels, while mean differences were only .101/.117 pixels. The unlit
black fill changes the thresholded raster at those ends. The final check records
those differences and checks the inner 90% separately; it does not claim exact
raster identity with a shaded, highlighted eye.

## Remaining work

Evaluate the new full smile and the transition without shrinking the eyes back
into small strokes. Intermediate highlights intentionally fade with happiness;
this is not yet a final timing choice. Small light/dark edge slivers are still visible in oblique views; the zero-white
measurement above is frontal, not an all-view claim. The broad pink patch and lid boundary
artifacts still affect the complete expression and remain the next structural
work. Do not call them fixed because the black silhouette is improved. Mouth/audio
fine-tuning remains deferred. Other runtimes, whole-body skinning/poses, gaze,
SpringBone and full-pipeline reconstruction are still outstanding.
