# Manga smile-eye prototype

## Scope

`happy-arc` adds an upward-curved eye seam to the accepted `mouth-aa-aligned`
model. It is a comparison candidate, not an owner-approved replacement. The
owner approved the greeting's naturalness before this stage. Keep the original
head, mouth and selected manga eyelids as the reference.

Open `viewer.html?model=happy-arc&motion=1&audio=greeting&happy=1`.
The **にっこり** slider controls happy strength; zero restores the accepted eyes.
At full strength the eyes close into an arc. Intermediate values keep an opening.
The greeting and manual vowel controls work independently of happiness.
No automatic emotion selection or smile timing is embedded in the audio.

## Reproduce

Prepare the accepted blend/VRM and the greeting fixture following
[BASELINE.md](BASELINE.md) and [SPEECH.md](SPEECH.md), then run:

```sh
BLENDER_BIN=/path/to/Blender mise run happy-probe
```

This builds `artifacts/happy-arc` and `artifacts/happy-arc-repeat`, imports the
first VRM into Blender to check bindings, and runs the browser comparisons.
Existing files in these two trial directories are replaced. The accepted input
is hash-checked and cannot be used as the output directory. No dependencies,
source textures or accepted artifacts are changed. Models and screenshots stay
in ignored local storage.

## Method and failed first attempt

The standard VRM `happy` preset copies the selected blink's four texture
transforms and two source-eye clearance morphs. Four new `HappyArc` morphs raise
the shared upper/lower lid seam while retaining the shell perimeter. Default
maximum added height is 0.035 model units. The original 0.008 curve remains part
of the baseline. `HAPPY_HEIGHT` permits separate local comparisons in (0, 0.06].

The first trial moved vertices only upward. It exposed patches of the original
black eyes through the lower lids because depth no longer followed the curved
surface. The corrected target re-samples depth from the original lid columns
at each moved vertex's new height. This removed the visible holes in the checked
views. It is a shape-specific fitting method, not a general collision solver.

`happy.overrideBlink=blend`, `happy.overrideMouth=none`. The viewer applies
`happy=h`, `relaxed=(1-h)*r`, so competing emotion contributions do not exceed
one. The resulting closure with blink `b` is:

`h + (1-h)*r + (1-h)*(1-r)*b`

The arc morph itself stays at weight `h`. This gives a fully closed, curved eye
during a blink even when happiness is partial. External drivers must apply the
same emotion weighting contract rather than sending full happy and relaxed
simultaneously. The standard VRM override handles blinking; no custom shader is
required. The mouth's non-mipmapped sampler patch is retained after export.

## Evidence — 2026-09-28

[results/happy-evaluation.json](results/happy-evaluation.json) records:

- 26 framebuffer comparisons at happiness zero, including neutral, blink,
  relaxation and all five vowels, exactly match the accepted model. The browser
  equalizes the control layout for these pixel comparisons.
- 36 happy/relaxed/blink combinations have finite, bounded morph weights, and
  their actual lid texture offsets match the closure formula. Mouth weight is
  retained. These samples do not cover all continuous combinations.
- Live greeting playback overlaps happiness and blinking and ends normally;
  vowel total remains at most 0.8 with the default strength.
- Front, oblique, both side views, intermediate/full happiness, and a mixed
  relaxed/blink state were inspected. Layouts at 1280/600/390 px fit horizontally.
- Two generated VRMs match byte-for-byte. Blender reimport resolves the six
  happy morph binds and four texture binds plus the previous expressions. This
  validates bindings, not identical Blender shading after a round trip.

Candidate SHA-256:
`f55b65edabafc468beedd3e9e111494c586f28c8ab8df10ed124f6059171d828`.
Accepted source SHA-256 remains
`cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31`.
The existing silent-motion regression also passes and restores neutral exactly.

## Next decisions

Evaluate the artistic appearance, including whether the curved eyes read as a
smile at full and partial strengths. The existing raised-eye shading remains;
this candidate does not flatten or replace the original eyes. Do not silently
promote it to the accepted baseline. Refine this expression or add a small
worried/surprised comparison next, then address gaze, springs and full pipeline
reproduction. Automatic speech alignment and the final character voice remain
separate open items.
