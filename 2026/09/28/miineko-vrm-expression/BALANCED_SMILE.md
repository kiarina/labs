# Upper-led smile closure with a shared start

## Accepted comparison baseline

On 2026-09-29 the owner judged `sync-smile` sufficient to move on, while allowing
later refinement of the 7:3 ratio. Keep this artifact as the smile reference.
The next [angry/sad probe](EMOTIONS.md) extends it without replacing its geometry
or existing expressions. Skin-color and perimeter issues are still outstanding.

## Closure direction — 2026-09-29

The owner found the [crescent smile](CRESCENT_SMILE.md) frightening and proposed
upper 70% / lower 30% closure, keeping the highlight unchanged until the upper lid
covers it. The resulting `balanced-smile` was judged substantially improved.
The next correction was to start both lids together: the smaller lower movement
should be slower, not delayed. The current candidate is **`sync-smile`**.

Open `expression-study.html?variant=sync&happy=.13&opening=0&angle=0`.
The selector retains `balanced-smile`, which had a later lower-lid onset, and
older candidates. Mouth control stays independent. Head, nose and source mouth
are unchanged. The pink-lid color/perimeter artifacts remain unresolved, and
the owner accepted this smile as a minimum-quality baseline, not a finished avatar.

## Visible travel, onset and endpoint

Source eye artwork is sampled along each center column at .00025 model-unit
intervals. Achromatic black/highlight texels define the visible limits, rather
than the oversized invisible lid shell. Sampled top/bottom coordinates are
.69425/.52525 (L) and .69425/.52550 (R). The former balanced version retained a
.024-wide central gap and assigned 70/30 of the closing travel to upper/lower.
After its initial physical clearance, visible upper shares were approximately
.70276. This is central vertical travel, not the covered fraction of the entire
eye area or a physiological rule.

The former builder used the same UV scale, alpha margin and physical clearance
for both lids. The smaller lower travel took longer to cross that margin. In the
fixed frontal samples it first moved at .16, versus .08 for the upper lid.

The synchronized candidate keeps the **full endpoints** of that balanced version.
Let the visible movement at full strength be `D`. Neutral clearance is now a
common fraction, .01, of each lid's own total movement: `T=D/(1-.01)`, with
clearance `.01*T`. Each lid's UV scale is `.35/T`, so its full VRM V shift is
exactly .35. The same .02 neutral alpha guard now consumes the same normalized
progress in both lids, instead of delaying the lower one. Curve terms are scaled
with the same UV factor; the full smile's .055 rise coefficient is retained.
Ink distances are rescaled to retain the prior blink/relaxed stroke dimensions.

A short **shared initial dead zone** remains: .02/.35 is about .057. The left upper/lower first move at .06/.06 and the right at .06/.08 in the
sampled central raster (a .02 sampling interval). This does not assert motion from
an infinitesimal nonzero weight or simultaneous onset in every eye column.
At .13 the upper travels farther while the lower has already started. Endpoint
coordinates match the previous balanced version numerically; filtering can still
change the rendered edge by about a pixel.

The source highlight keeps its color. There is no black eye fill and no happy
material-color bind. Pink reveal layers alone cover the eye. The extra upper ink
remains inactive for a pure smile. Normalized eye weights and independent vowel
control are as in [SURFACE_EXPRESSIONS.md](SURFACE_EXPRESSIONS.md). Blink and relaxed
endpoints are retained but their onset uses the new common mapping as well.

## Reproduce

Prepare the input/control artifacts using [BASELINE.md](BASELINE.md),
[CONNECTED_VOWELS.md](CONNECTED_VOWELS.md), and the preceding expression studies.
Keep the pinned Blender/VRM add-on, Node and comparison Python environments.

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run sync-smile-probe
```

This replaces `artifacts/sync-smile`, `-repeat` and captures in
`artifacts/sync-smile-review`. Private binaries, images and coordinate audits
stay ignored. The previous candidate remains reproducible with
`mise run balanced-smile-probe`, which writes its own directories.

## Current evidence and limits

- [Onset measurements](results/sync-smile-onset.json): source-matched frontal
  captures at 0/2/4/6/8/10/13/16/20/50/100%, separately for both eyes and both
  candidates. First motion is a median displacement of at least one pixel across
  five central columns. Compare onset, endpoint displacement and unchanged bright
  pixels, rather than just checking exported expression weights.
- [Geometry/import](results/sync-smile-geometry.json): body coordinates and vowel
  binds unchanged; fixed source-following planes; matching normalized clearance
  and UV travel; old/new full endpoints preserved; no black fill or color bind.
- [Runtime](results/sync-smile-evaluation.json): source comparisons for five vowels
  × five views in two candidates, 120 expression/view samples, early-onset
  captures, 27 mixed weights, live cycle, frontal reset, three screen widths and
  repeat-byte equality. Read the recorded pixel deltas: neutral comparisons are
  not all exact.

Changing the UV mapping exposed small oblique/perimeter residuals at neutral.
In the initial focused check the new candidate had 7 changed pixels (max channel
6/255) at +45°, one pixel (8/255) at +90°, and four pixels (35/255) at -45°;
front and -90° matched. The runtime test records deltas per comparison and bounds
only this candidate to at most ten pixels and 40/255; the older balanced control
retains its tighter two-pixel, 1/255 limit. This is an acknowledged rendering
limitation, not exact neutral parity or a solved boundary. Its cause is not fully
resolved. The visible larger skin-color seam also remains.

## Earlier balanced results and failed checks

The preceding fixed frontal captures had upper shares of 70.6–71.8% at
25/50/75/100%; full strength was 70.8% (L), 70.6% (R). At 50%, 993/1,142 bright
source pixels remained exactly unchanged. At 75/100%, frontal bright counts
were zero without color changes. See [motion](results/balanced-smile-motion.json),
[geometry](results/balanced-smile-geometry.json), and
[runtime](results/balanced-smile-evaluation.json) for those historical values.

Strict neutral checking first failed near the eye edges. Increasing the old UV
margin from .498 through .49 to .48 and excluding near-degenerate lid triangles
(the source body stays intact) reduced but did not remove the residual: 45 of
50 comparisons were exact; five right-oblique comparisons each differed in one
pixel by 1/255. The new normalized UV mapping must not inherit that tighter result
as if it had been re-established. The reimport check also needed scratch materials
cleared to avoid confusing Blender's `.001` name suffixes with canonical names.

## Next work

Keep the accepted shared-start smile as the reference while comparing the new
[angry/sad directions](EMOTIONS.md). Refine the ratio and remaining skin-color
patches, sharp reveal boundaries and oblique edge slivers after the basic
expression set has been evaluated.
Do not return to highlight painting to conceal a lid-position problem. Mouth/audio
polish remains deferred; full poses/skinning, other runtimes, gaze, SpringBone and
end-to-end generation remain open.
