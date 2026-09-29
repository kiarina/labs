# Bring ordinary blinking in line with the accepted expressions

## Owner request and candidate — 2026-09-29

After accepting the basic emotion directions, the owner identified ordinary
blinking as visually older: upper/lower travel, the 100% endpoint and line weight
had not followed the newer expressions. `blink-aligned` was accepted by the owner on 2026-09-29. Its unchanged input is the accepted
[surprise-ears](SURPRISE_EARS.md) model.

Open `expression-study.html?variant=blink-aligned&blink=1&opening=0`.
Use **目を閉じる**, **まばたき1回**, and **まばたきをゆっくり**; select
**比較：以前のまばたき（口＋耳）** for the previous blink. Ordinary and slow
one-shot previews last 360 and 2800 ms. The first 38% closes, 7% holds, and the
remaining 55% opens, using smooth interpolation. These timings are review aids,
not an accepted natural timing specification. Reset or another eye control
cancels the pulse. Ear and mouth values remain independent.

## What changed and why

The old blink still used roughly .076 upper / .097 lower travel and a separate
upper-ink layer. Visible lower movement started earlier, and the final line was
much thinner than the accepted emotion bands. The new closure reuses happy's
upper/lower travel, neutral origins and common normalized UV shift. Both start
from the same normalized clearance; upper travel is approximately 70% of the
total. There is no added lower-lid start delay.

The endpoint keeps happy's central .024-unit black band, but reduces the arc rise
from happy's .055 to .008 and applies no tilt. This is a shallow, almost straight
closed eye, distinct from the pronounced smile. The extra moving upper-ink layer
is inactive, so the line comes from the remaining original eye artwork. Its
highlight is neither recolored nor faded; the upper lid covers it.

`scripts/refine_blink.py` replaces only the standard `blink`, `blinkLeft` and
`blinkRight` preset objects. The latter two apply the same method to their own
side. Binary geometry, textures, normals, ears, mouth and all other expression
settings are identical to the input. Matching binds are saved to a copied blend.
The eye driver still blends happy/angry/sad/relaxed toward this ordinary blink;
it does not preserve a separate expression-specific 100% closed-eye endpoint.
Inspect these intermediate mixtures before choosing any further driver changes.

This does not repair the inherited pink color patches or perimeter seams. Exact
line thickness, curvature, onset and timing remain artistic review items.

## Reproduce and evidence

Prepare the source chain in [SURPRISE_EARS.md](SURPRISE_EARS.md), then use the
pinned environment from [BASELINE.md](BASELINE.md):

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run blink-aligned-probe
```

Outputs: `artifacts/blink-aligned`, `-repeat`, and `artifacts/blink-aligned-review`.
The source accepted model is retained. GUI re-export is still not equivalent to
the validated runtime file without the earlier export patches.

- [Structure/import](results/blink-aligned-structure.json): only three blink
  presets differ; the binary chunk is identical, saved/imported binds agree,
  and separate builds reproduce the same VRM bytes.
- [Runtime](results/blink-aligned-evaluation.json): 30 retained views match the
  source, 48 old/new blink captures, 15 emotion/blink/mouth combinations, both
  unilateral presets, ordinary/slow pulse completion, independent ears/mouth,
  pulse cancellation/reset and 1280/600/390 px layouts.
- [Central movement](results/blink-aligned-onset.json): old upper movement first
  appears at .08 and lower at .04. New first movement is .06/.06 on one eye and
  .06/.08 on the other, at the sampled 2% resolution. Full upper share is
  approximately 70.6%/70.2%, with a 24 px central band in this fixed camera.
  At .13 the visible highlight pixels remain unchanged; no bright highlight
  remains inside the eye crops at full closure. These are central five-column
  measurements, not proof of identical onset everywhere on the eye.

Next: retain the accepted closed-eye shape while checking broader transitions. Keep
accepted emotion endpoints and the raised-ear surprise intact. Ear reaction
timing, broader transitions and mouth/audio polish follow this correction.

## Saved private snapshot

At the owner’s request, byte-identical copies of this stage’s blend and VRM are
saved in the private assets repository as
`miineko/tripo/v1/miineko-blink-aligned.{blend,vrm}`. Those files were removed when
assets became a finished-files-only store; they and the adjacent README with
hashes and provenance remain at assets commit `6d75075`. All file-backed images in the blend are packed. This
snapshot does not automatically track later lab edits; use the lab recipe for
rebuilding rather than treating a GUI export as equivalent to the saved VRM.
