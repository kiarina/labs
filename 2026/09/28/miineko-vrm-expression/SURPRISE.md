# Surprise: mouth-only versus subtly taller-looking eyes

## Question and scope — 2026-09-29

After provisionally accepting the steeper sad eyes, the owner approved comparing
surprise starting with the existing round eyes and a small vertical mouth. The
sticker sheet's fourth row, third column is a reference, not an exact target.
The second option makes the eye look slightly taller by covering its sides;
it does not enlarge the eye vertically or deform the pink head.

Open `expression-study.html?variant=surprise-mouth&vowel=oh&opening=.65`.
Switch between **驚き：口だけ** and **驚き：目を少し縦長に**. The **あれ？** button
selects OH at opening .30 and eye strength .40; **えっ！** selects OH at .65 and
eye strength 1. The mouth-only option ignores eye strength. These are starting
poses, not an assertion that their emotional reading is settled. The original W
still gives the open mouth a cheerful quality; the owner has not evaluated the
surprise direction yet. Keep the accepted happy/angry/relaxed/sad references.

Mouth opening, vowel and eye strength remain independently controllable. The
existing `early` mouth response is q^.6, so the displayed opening is not the raw
VRM vowel weight. The viewer's `surprised` eye weight participates in the same
normalization as happy/angry/sad; blink suppresses those weights, with relaxed
using the remainder. The slow emotion cycle still covers the preceding four
emotions. Use the two surprise buttons for these new comparison poses.

## Construction

`scripts/build_surprise_probe.py` reads `eye-emotions-steeper/continuous-blink.vrm`
and appends two fixed side masks, using the existing upper-lid triangle surface,
skin colors, normals, skinning and eye-artwork mask. Original geometry, images,
binary data and existing expression objects are preserved. The white highlight
is not repainted or moved. Side masks restrict their coverage to the original eye
artwork, avoiding new pink patches on the surrounding head. Their surface is
.00005 units in front of the existing upper-lid surface.

The horizontal reveal coordinate follows an elliptical boundary around each eye
(center z=.619, x radius .104, z radius .14). Its neutral coordinate is clamped
inside the transparent interval. Standard VRM texture-transform binds scale U
from 1 to 1.35 around its center. This mildly narrows the visible eyes as strength
increases. It is not a rigid eye stretch and not a physiological widening motion.
A procedural 1024×4 alpha texture uses linear filtering without mipmaps.
`alphaMode=MASK`, cutoff .01, avoids transparent-depth interference. A narrow edge seam remains visible beside the covered eye artwork. The renderer
and existing material limitations still apply; this is a direction probe.

Initial unrestricted skin masks produced conspicuous pink patches and a small
neutral-view difference at oblique angles. Restricting vertex alpha to the source
eye artwork removed those new surrounding patches and restored the checked
neutral/existing-expression views. A 1.20 U scale gave very little visible change;
1.35 is the current comparison. These trials did not modify the source model.

The new `surprised` VRM preset contains **only the eye binds**. The OH mouth is a
viewer-composed pose, not embedded in that preset. This keeps mouth motion
independent. This stage assembles a runtime GLB directly; no matching new
Blender authoring file is generated. Blender import and target-runtime behavior
of this new probe are not yet validated. Do not describe the full generation
pipeline or arbitrary speech as complete.

## Reproduce and evaluate

Use the pinned Python/NumPy/Pillow and Node/three-vrm environment in
[BASELINE.md](BASELINE.md), with the source chain in [EMOTIONS.md](EMOTIONS.md).

```sh
COMPARE_PYTHON=.venv/bin/python mise run surprise-probe
```

Outputs are `artifacts/surprise-eyes` and `-repeat`, with private screenshots in
`artifacts/surprise-review`. All remain ignored. The script appends data and
checks input SHA-256 against the source report. Separate outputs reproduce the
same VRM bytes. [Runtime evidence](results/surprise-evaluation.json) covers
30 source-versus-candidate views at eye strength zero, 50 comparison states,
27 mixed eye states, preset buttons, reset, a full silent vowel cycle, and
1280/600/390 px layouts. Pixel equality of retained states and weight validity
are distinct from judging whether the new expression is cute or surprised.

Next: owner evaluation of the two directions; then integrate the chosen design
into the authoring route and check transitions with the other expressions.
Skin seams, precise eye ratios and mouth/audio polish remain later work.
