# Local highlight shading cleanup

## Request and scope — 2026-09-29

After reviewing the dance, the owner moved to small quality improvements,
starting with the dark dirt-like mark inside the right eye's white highlight.
The current candidate interprets right as the character's right, **screen left
in a front view**, material `Original eye material R`. This side has the clear
dark patch near the top of the white area. A clarification about viewing-side
terminology was requested; the comparison makes the selected side explicit.
Do not silently apply this repair to both eyes.

Open `expression-study.html?variant=highlight-clean-r&opening=0&blink=0` and
compare with `blink-aligned` (the saved accepted source). The source `.blend`,
VRM and earlier assets snapshot remain preserved. This repair was subsequently
included in the owner-fixed [version 1](VERSION_1.md); its earlier pending-review
status no longer describes the current baseline.

## Diagnosis and repair

A dark mark inside a white highlight is not sufficient evidence of dirty paint.
Use fixed camera, pose, lights and renderer settings, and distinguish these tests:

| Diagnostic | What changed | Observation and justified conclusion |
| --- | --- | --- |
| Original shaded material | Nothing | The upper highlight has a dark patch. This alone does not identify its cause. |
| Normal texture disabled | Eye material normal-map strength only | The coarse patch remains. Disabling the normal map is insufficient. |
| Unlit base color | Lighting/material shading removed, base-color image retained | The interior patch disappears. Shading contributes; this test alone does not distinguish vertex normals, roughness and other lighting inputs. |
| Local vertex-normal repair | Selected highlight normals only; original maps and material retained | The prominent patch improves. This isolates a vertex-normal contribution without changing the artwork. |

These diagnostics are temporary views, not production material changes. Do not
leave the whole eye unlit or remove its normal map as an incidental cleanup.
Do not infer that every dark rim, texture seam or future artifact has the same
cause. The persistent fix below is deliberately narrower than the diagnostics.

`scripts/refine_highlight_normals.py` samples the existing eye texture to select
58 bright-highlight vertices. It fits a quadratic surface to 296 surrounding
dark-eye vertices and gives only those highlight vertices a smooth surface-normal
field. The normal texture itself is retained. The runtime GLB appends a replacement
normal accessor; all prior binary data and all JSON except that accessor binding
and buffer metadata are unchanged. No UV, position, triangle, image, expression
binding, skin weight, opposite-eye normal or ear morph is modified.

The copied authoring blend receives the corresponding split-corner normals.
Use nearest position matching within 2e-6 model units for matching authoring and
exported vertices; direct dictionaries of rounded float32 and float64 tuples
can fail equality even at visually identical coordinates. All selected distinct
positions must match. Saved split normals are quantized by Blender, so the check
allows <.001 difference; measured maximum is about .000407.

This removes the prominent upper interior stain. It is not a perfectly white
unlit decal: the highlight retains its texture, normal-map detail and lighting.
The irregular outer contour/rim and inherited eyelid seams are separate work.
Interpolation may affect pixels immediately adjacent to the white patch; it is
not a per-pixel masking operation.

## Verification and future-edit discipline

- Keep a source/candidate pair and name the side in both character and screen
  coordinates. Material names alone can be ambiguous to the person reviewing.
- Confirm which data actually changed. This repair changes normals, not geometry
  or texture pixels; a visual improvement does not justify describing all eye
  data as untouched.
- Inspect the open eye, partial coverage, and full closure. Matching full-closure
  renders tests that hidden highlight changes do not leak into closed-eye poses;
  it does not prove all intermediate weights or all lighting environments match.
- Pixel counts are tied to the recorded camera and resolution. The changed-pixel
  bounding box reports where differences occurred; it is not an independent
  semantic segmentation of the white circle. Adjacent black pixels can change
  through interpolated normals even when their vertices are unmodified.
- Check saved Blender normals separately from runtime GLB normals. Their vertex
  and corner counts differ because of seams; compare by position with a stated
  tolerance rather than relying on list indices or float32/float64 tuple equality.
- Keep the earlier `blink-aligned` snapshot as a historical reference.
  Documentation requests and viewer navigation alone are not approval or a request
  to overwrite `assets/miineko/tripo/v1/`.

## Reproduce and evidence

Use the `blink-aligned` input and pinned tools from [BLINK_ALIGNED.md](BLINK_ALIGNED.md)
and [BASELINE.md](BASELINE.md):

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run highlight-normal-probe
```

Outputs: `artifacts/highlight-clean-r`, `-repeat`, and `artifacts/highlight-review`.
The source JPEG copied into the output for reading is byte-identical source data,
not an edited bitmap. For the optional diagnostic, run from this lab directory
after the localhost viewer is serving and `artifacts/highlight-review` exists:

```sh
node scripts/inspect_highlight.mjs
```

It writes `original.png`, `no-normal.png`, and `unlit.png` in that directory. Its
fixed diagnostic camera differs from the main evaluation detail camera; compare
images within each series rather than mixing their pixel measurements.

- [Structure](results/highlight-normal-structure.json): 58 normal vertices differ;
  other JSON/source bytes, image/UV/geometry/expressions remain intact. Separate
  builds match and 107 saved blend corners match the intended normals.
- [Runtime](results/highlight-normal-evaluation.json): 80 source/candidate views
  spanning neutral, partial closure, closed eyes and emotion poses in five views.
- [Pixels](results/highlight-normal-pixels.json): detail changes are localized to
  screen-left highlight vicinity; 292 previously dark pixels become bright in
  that view. Opposite eye is unchanged. Twenty-five fully covered-highlight
  views across blink/happy/angry/sad/relaxed match exactly.

This repair is included in version 1. Additional visual improvements belong to
a separate later revision. Whole-body ribbon/arm observations remain open;
they were not repaired as part of this localized eye change.
