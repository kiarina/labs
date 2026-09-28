# Thinner face features: static design comparison

## Current direction

The owner rejected `happy-arc`: closed eyes retained round protrusions and did
not feel cute or close enough to the sticker reference. The new goal is a round
head with shallow, surface-following facial features and shorter, thicker smile
lines. The sticker sheet remains guidance, not an exact-match requirement.
Additional character images inform the visual direction; their internal rigging
or rendering techniques cannot be established from the images alone.

`mouth-aa-aligned` remains the previous appearance/motion reference. Its original
eye and lip volume is no longer a constraint for new designs. Earlier successful
pixel comparisons and motion tests remain valid for that reference, not approval
of these new faces.

## Compare

Serve the lab locally and open
`face-study.html?variant=eyes-mouth&pose=smile&angle=0`.

| Choice | What changes |
| --- | --- |
| これまでの顔 | `happy-arc`, at happy 0 or 1. Its neutral face matches the earlier baseline. |
| 目を薄く | Smoothed front face, shallow graphic eyes or short smile strokes; source nose/lips and their local shading retained. |
| 目と口を薄く | Same graphic eyes, plus shallow nose, stem and W mouth on a continuous smooth face surface. |

Normal/smile and five camera angles can be switched without changing the camera
framing or lights. These are **static form studies**. The four new files have
their old expression binds cleared; blinking, vowels and audio driving have not
been adapted. Do not load them as if they were a completed expressive avatar.
The previous working audio viewer remains linked from the comparison page.

The thin mouth also changes line width and placement, and the new eye highlights
are simplified. This is a design comparison, not a controlled test isolating
depth as the only variable. Skin texture/normal-map treatment changes too.

## Method and reproduction

Use the original local `mouth-aa-aligned/continuous-blink.blend` and the pinned
Blender/VRM add-on from [BASELINE.md](BASELINE.md). The browser also needs the
earlier `happy-arc` and existing Node dependencies.

```sh
BLENDER_BIN=/path/to/Blender mise run thin-face-probe
```

The task generates four normal/smile variants and four separate repeat files,
then renders all comparison states. It replaces only `artifacts/thin-*` outputs.
It does not modify the earlier source artifacts. All blends, VRMs and captures
are ignored local files; source artwork is not published.

`build_thin_face_study.py` changes only depth on the original mesh's front face.
Every original vertex retains its x/z coordinates. The target is an ellipsoidal
front surface (x radius .445, z radius .34, depth radius .31, center y .04/z .635),
blended into the existing shape around the face perimeter. The eye-only variant
protects the source nose/lip area. This preserves the frontal silhouette while
intentionally changing the side profile; it is not a replacement of the whole
head with a sphere.

The old normal map and texture shading can suggest raised eyes even after mesh
flattening. A feathered skin surface therefore covers the old frontal features.
Its procedural vertex color is the linearized median of clean pink source samples
around the boundary. Source bitmap files are read but not changed. Normal maps
are not applied to this surface. Eyes, highlights and line strokes are new meshes
with standard unlit materials, fitted to the same surface with small depth offsets.
No camera-facing billboard or custom viewer shader creates the face.

The cover is reprojected against the actual deformed body triangles to avoid
small exposed polygon edges. Graphic feature offsets are approximately .004
model units from the support surface, with the skin cover at .0025; these are
model-space settings, not a guarantee of uniform physical thickness everywhere.
The head bone still carries the meshes. Expression binds are cleared because the
old clearance/mouth shapes were calibrated for the protruding geometry.

## Attempts and observed limits

An initial approach fitted separate quadratic patches around both eyes and the
mouth. Joining them produced conspicuous shading folds. A continuous face target
improved that result. Isolated eye covers also left bright crescents from old
shading; the present comparison uses the broad face cover, preserving only the
mouth area for the eye-only control. Reprojecting the cover against the deformed
mesh removed visible polygon fragments near that preserved region.

Skin transitions remain visible, especially around the retained mouth and along
the chin/perimeter. The source body's textured appearance and the smoother face
are not yet fully matched. Nose shape, highlight position, eye size/placement and
mouth stroke styling are also reviewable. Do not interpret numerical checks as
artistic acceptance or as finished material work.

## Validation — 2026-09-28

[results/thin-face-evaluation.json](results/thin-face-evaluation.json) records
30 rendered states: three designs × two expressions × five views. All displayed
the intended model without page errors. Widths 1280/600/390 px fit horizontally.
Each of the four generated VRMs matched its separate repeat byte-for-byte.

Original vertex x/z positions remain identical. The eye-only variant changes
2,225 original vertices in depth, with maximum absolute change .051054 model
units; the eye-and-mouth variant changes 2,622, maximum .063834. These are whole
region depth changes, not a direct measure of perceived feature protrusion.
The source VRM SHA-256 remains
`cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31`.

Next choose/refine the static appearance, match skin transitions and feature
styling, then reconstruct blink/relaxed/vowel behavior on the chosen surface.
Reuse playback and verification infrastructure, but recalibrate the geometry and
rerun its composition checks. Gaze, springs, whole-pipeline reproduction and final
distribution metadata remain outstanding.
