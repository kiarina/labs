# Full-body deformation check before further expression polish

## Scope and outcome — 2026-09-29

The owner moved whole-body testing ahead of ear reaction timing and further
facial polish. This experiment **plays the accepted `blink-aligned` model without
editing it**. Its SHA-256 matches the saved private asset snapshot:
`fa6d47e4f9ca669a5ebded7ceccea3d7cd44208b76d3a288840e8554436a4b33`.

The first checks did not show global mesh explosion or detached body parts, but
**the model is not yet a pass for unrestricted full-body motion**:

| Observation | Reproduce | Interpretation / next check |
| --- | --- | --- |
| Hands/arms disappear into the large head at high arm elevation. | `arms`, 1.5 s, front and side | Limb motion needs adaptation to this short-armed, large-headed character. This alone does not prove broken skin weights. |
| Lower ribbon strongly folds during deep crouch and high kick. | `squat` / `kick`, 1.5 s, side or oblique | Review ribbon weighting before facial polish. Local red-front-region samples include hips/upper-leg influence as well as head/chest/shoulders. |
| Dance remains recognizable and connected in sampled views; feet can penetrate/slide relative to the grid. | `samba`, full 18.2 s | No foot IK or contact correction is applied. Motion-height scaling is not contact solving. |
| Broad head/torso bends and twists are viewable, with face overlays still following the head in checked combinations. | `twist`, 1.5 s; `samba`, 4.55 s, facial controls | Inspect closer before certifying every combination or repairing weights. Existing face seams remain. |

The ribbon evidence is in [body-ribbon-weights.json](results/body-ribbon-weights.json).
A texture/color and geometric-region filter selects 2,195 seam-split vertices;
upper-leg weights reach approximately .268/.239. This is **a candidate ribbon
region**, not exact semantic segmentation. It supports a weight review, not an
automatic prescription to zero all leg weights or rigidly bind every red vertex.
Keep the accepted normal shape, source assets and expressions intact while
preparing a separate repair candidate.

## View and inspect

- `body-study.html`: normal pose, five deliberately large joint sweeps, and a
  retargeted Samba Dancing clip. Pause, seek, 30 Hz single steps, quarter speed,
  front/oblique/side/back views, optional bones, and three expression combinations.
- `body-review.html`: the saved video and a contact sheet. Pick a motion/view;
  clicking an image opens the exact sampled time in the live viewer.
- `artifacts/body-motion-review/samba-45.mp4`: 960×824 H.264, 15 fps, 274 frames,
  18.267 s including frame quantization of the 18.200001 s source.
- `artifacts/body-motion-review/samba-frames/`: individual 15 Hz JPEG frames.
- `artifacts/body-motion-review/arms-recording.webm`: exercised browser recording
  of a complete 3 s authored arm sweep. The UI's **1周を録画** records the current
  clip through `canvas.captureStream` / `MediaRecorder`; file saving is separate.

Offline frame export evaluates `i/15` seconds explicitly, so screenshot latency
or a hidden tab does not determine the pose time. This is distinct from real-time
UI recording, which can drop frames and stops when the page is hidden. It is not
a claim of identical raster/video bytes across GPU/encoder versions. Seeking
backwards after reaching the end is tested for matching rendered output.

## Motion source and retargeting

The dance is the public three.js FBX example's **Samba Dancing** asset, whose
animation is named `mixamo.com`. [Pinned provenance and checksum](results/body-motion-source.json)
identify the original repository commit and binary. No private model was sent to
Mixamo or another service. The downloaded motion is ignored local test data;
do not assume three.js's code license grants unrestricted redistribution of all
example media. No motion binary is committed to this public repository.

The rest-frame rotation method follows the
[pixiv three-vrm humanoid animation example](https://github.com/pixiv/three-vrm/tree/dev/packages/three-vrm/examples/humanoidAnimation).
Twenty-two body bones map to normalized VRM humanoid nodes. Finger tracks are
intentionally skipped in this first body test. Only hips receive a translation
track; copying source limb translations would resize the mascot's skeleton.
Source hips motion is offset from its rest position and scaled by the ratio of
hip heights, approximately .0012066 for this asset and model.

This FBX contains duplicate bone names. Selecting the last traversal match
initially picked a zero-height duplicate hips node and produced invalid values.
The loader now selects the first hierarchy match consistently with track-name
lookup, and rejects a nonfinite/nonpositive scale. That was a **retargeter bug**,
not evidence of broken model skinning. LoopOnce clips also pause at their end;
seeking explicitly unpauses them before setting time so replay does not freeze.

The authored 3 s sweeps are diagnostic exercises, not production animation:
arm elevation/elbow bend, hip/knee crouch, a high kick, torso/neck twist and a
jump-shaped translation. Their amplitudes are in `scripts/body_study.mjs`.
They are not biomechanically solved, do not implement foot contact, and the jump
is not a captured jumping motion. These simplify cause isolation alongside the
external dance clip.

## Reproduce and evidence

Prepare the accepted model using [BLINK_ALIGNED.md](BLINK_ALIGNED.md). Use the
pinned Node/three/three-vrm/puppeteer and Python/NumPy/Pillow in [BASELINE.md](BASELINE.md),
plus installed Chrome and FFmpeg (tested with 9.0.2 on macOS arm64):

```sh
COMPARE_PYTHON=.venv/bin/python mise run body-motion-probe
# Serve this directory for interactive review, then optionally capture its gallery:
python3 -m http.server 52714 --bind 127.0.0.1
# In another terminal:
node scripts/capture_body_review.mjs
```

`fetch_body_motion.py` downloads the pinned source only if absent/different and
checks its SHA-256. Other scripts start their own temporary local HTTP servers;
only gallery capture uses `STUDY_URL` (default `http://127.0.0.1:52714`).
Model, motion binary, videos and screenshots remain in ignored artifacts.

- [Runtime report](results/body-motion-evaluation.json): 38 sampled poses across
  normal pose, five sweeps and dance, 152 four-view captures, finite skinned
  positions/bones, facial combinations, three viewport widths, source hash
  preservation. Finite vertices are not a collision or quality test.
- [Recording](results/body-motion-recording.json): absolute-time frame export,
  repeatable seek, browser recording produces a nonempty WebM.
- [Encoded video](results/body-motion-video.json): codec, frame count and duration.
- Gallery images, video metadata and exact-time navigation were exercised.

Next prioritize a separate ribbon-weight repair and character-appropriate arm
motion limits, then repeat the same views/timestamps. Ear timing, mouth/audio,
gaze and SpringBone remain later integration work. Do not overwrite the saved
assets snapshot during diagnosis.
