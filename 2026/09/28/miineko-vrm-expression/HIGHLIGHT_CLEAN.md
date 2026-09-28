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
VRM and assets snapshot remain unchanged. Candidate approval is pending.

## Diagnosis and repair

An unlit base-color diagnostic removed the interior dark patch, while disabling
the normal texture alone left the coarse shading problem. This identifies a
vertex-normal contribution; the mark is not simply dark paint in the base-color
image. Preserve the actual artwork rather than generatively repainting it.

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

## Reproduce and evidence

Use the `blink-aligned` input and pinned tools from [BLINK_ALIGNED.md](BLINK_ALIGNED.md)
and [BASELINE.md](BASELINE.md):

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run highlight-normal-probe
```

Outputs: `artifacts/highlight-clean-r`, `-repeat`, and `artifacts/highlight-review`.
The source JPEG copied into the output for reading is byte-identical source data,
not an edited bitmap. `inspect_highlight.mjs` is an optional lighting diagnostic
using the existing localhost server, not a production material modification.

- [Structure](results/highlight-normal-structure.json): 58 normal vertices differ;
  other JSON/source bytes, image/UV/geometry/expressions remain intact. Separate
  builds match and 107 saved blend corners match the intended normals.
- [Runtime](results/highlight-normal-evaluation.json): 80 source/candidate views
  spanning neutral, partial closure, closed eyes and emotion poses in five views.
- [Pixels](results/highlight-normal-pixels.json): detail changes are localized to
  screen-left highlight vicinity; 292 previously dark pixels become bright in
  that view. Opposite eye is unchanged. Twenty-five fully covered-highlight
  views across blink/happy/angry/sad/relaxed match exactly.

Next: confirm the intended side and appearance with the owner, then continue
small quality improvements. Whole-body ribbon/arm observations remain open;
they were not repaired as part of this localized eye change.
