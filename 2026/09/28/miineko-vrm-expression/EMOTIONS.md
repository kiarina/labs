# Angry and sad directions from the accepted smile eyes

## Direction and scope — 2026-09-29

The owner judged `sync-smile` sufficient to move on, with possible later tuning
of the 7:3 ratio. Its full-strength black eye shape and angle were suggested as
a basis for angry and sad. This probe adds those two standard VRM presets while
retaining the accepted smile as a reference. The new emotions are candidates,
not yet owner-approved. Existing skin-color/perimeter artifacts remain deferred
rather than being described as solved.

Open `expression-study.html?variant=emotions&angry=1&opening=0&angle=0`.
**にっこり100% / 怒り100% / 悲しみ100%** select one expression directly. Sliders
allow intermediate strengths and mixtures. **表情をゆっくり切替** transitions
between neutral, happy, angry, sad and neutral. Mouth controls are independent.
The reference model is still available under **基準：にっこり**.

- Angry: the inner eye corner is lower than the outer corner.
- Sad: the inner eye corner is higher than the outer corner.

The full bands keep the smile's central vertical gap; their curvature is reduced
and their slopes are mirrored between eyes. No eyebrows, tear marks, mouth
frowns, geometry replacement or highlight darkening are added in this step.
Those are not needed to test the owner's shape/angle hypothesis.

## Construction

`scripts/add_eye_emotions.py` reads the accepted `sync-smile` VRM and blend. The
VRM is derived by replacing only the previously empty `angry` and `sad` preset
objects in its JSON chunk. The binary chunk and all other JSON fields, including
existing expressions, are preserved. This avoids re-export drift in a model whose
smile was already evaluated. The same new binds are written into a copy of the
authoring blend. Do not treat GUI export of that blend as identical to the
validated VRM; the preceding export patches still apply.

Both expressions reuse the four fixed pink lids. The two optional upper-ink binds
remain inactive, avoiding a second line. There are no new meshes, images, morphs
or color binds. Standard texture-transform binds translate and scale the existing
parabolic reveal texture. The source highlight remains visible until covered.

For local eye coordinate `x`, radius `r=.104`, base rise `k0=.004`, U scale `s`
and translated coordinate `q`, the edge contributes `-k0*(s*x/r+q)^2`.
Using `k=.024`, `s=sqrt(k/k0)`, desired slope `m=±.28`, and
`q=-m*r/(2*k0*s)` gives a flatter tilted band. V translation compensates the
constant `k0*q^2` term so the full-strength central upper/lower positions stay
those of the accepted smile. Angry uses positive m for source-left and negative
m for source-right; sad reverses them. Front-view raster checks verify the
intended screen-space directions rather than assuming the coordinate signs.

This translation is not a rigid rotation of the whole original eye. It changes
the visible band on the same face surface. At partial strength, interpolation of
the translated parabola creates a small nonlinear center shift, up to about
.0022 model units for this configuration. Therefore the smile's exact 7:3/onset
measurements are not automatically claims about angry/sad. Their intermediate
appearance must be evaluated separately.

## Driver contract

The viewer normalizes happy/angry/sad if their sum exceeds one, multiplies them
by `(1-blink)`, and gives relaxed the remaining emotion contribution. Blink
retains its own weight. All new overrides are `none`; mouth is independent.
This keeps the combined eye contribution bounded and preserves the old
happy/relaxed/blink behavior when angry and sad are zero. Other consumers must
respect the same normalization contract. A shared material supplies one blended
band; the implementation does not stack independent angry/sad drawing layers.

## Reproduce and evidence

Prepare the pinned environment and accepted source following
[BASELINE.md](BASELINE.md), [CONNECTED_VOWELS.md](CONNECTED_VOWELS.md), and
[BALANCED_SMILE.md](BALANCED_SMILE.md).

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run eye-emotions-probe
```

Outputs are `artifacts/eye-emotions` and `-repeat`, with private captures in
`artifacts/eye-emotions-review`. Existing models remain untouched.

- [Structure/import](results/eye-emotions-structure.json): binary chunk and every
  JSON field other than angry/sad are identical to the source. Saved and imported
  authoring binds agree; each new preset has six texture binds and no morph/color
  binds. Separate builds yield identical VRM bytes.
- [Runtime](results/eye-emotions-evaluation.json): 40 existing-expression/vowel
  comparisons match the accepted reference framebuffer exactly; 120 new
  expression/strength/mouth/view states, 81 normalized mixtures, one-click
  selection, live transitions, reset, and 1280/600/390 px layouts are checked.
- [Shape](results/eye-emotions-shape.json): both angry inner corners are lower and
  both sad inner corners higher in the fixed frontal sample. The largest dark
  band has the expected slope sign and no bright-white highlight at full strength.
  This is geometry/raster evidence, not automatic recognition of an emotion.

Source SHA-256:
`732548953ffc6076c32cab22991c24a8be4c43991831f538a7fea88aef28e3ca`.
The full output hash is recorded in the structure report. The accepted smile's
known oblique neutral residuals and lid-color boundaries are inherited, not fixed
by this expression-only change.

## Next work

Evaluate whether the two directions read as Miineko's angry and sad expressions,
including intermediate strengths and mouth combinations. Preserve the accepted
smile when refining them. Fine changes to 7:3, source-skin seams and mouth/audio
response can follow the basic expression set. Gaze, springs, full-body pose
checks, target-runtime checks and end-to-end reproduction remain outstanding.
