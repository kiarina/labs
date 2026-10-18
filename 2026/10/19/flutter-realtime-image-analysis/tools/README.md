# tools: Python reference fixtures and the YuNet conversion

This directory produces what the Dart port is checked against.

- `convert_yunet.py`: kiarina's YuNet (`face_detection_yunet_2023mar_int8bq.onnx`, run by kiarina
  through OpenCV) made loadable by ONNX Runtime: every constant DequantizeLinear becomes a float32
  initializer and the input height/width become symbolic. Output `models/yunet/yunet_2023mar_dequantized.onnx`
  (gitignored, sha256 in `fixtures/input.json`). The app ships it (`asset:`), since it is not hosted anywhere.
- `make_fixtures.py`: `fixtures/input.json` and `fixtures/frames.json` (committed) and, gitignored,
  `work/frames/*.rgb` (the input frames as RGB24) and `work/fixtures-bin/*.f32` (embeddings).
  Each frame is run through two paths:
  - **kiarina**: the real kiarina-agi-image helpers (kiarina-python commit `9d483457`,
    kiarina-agi-image 2.28.0): `detect_faces`, `crop_align_faces`, `embed_image(face)` (YuNet and
    SFace on OpenCV DNN), `detect_objects`, `crop_objects`, `embed_image(object)` (D-FINE and SigLIP2
    on ONNX Runtime)
  - **ref**: what the Dart port computes, in numpy: YuNet and SFace on ONNX Runtime (`ref_yunet.py`),
    the face warp of `ref_warp.py`, OpenCV's generic fixed-point resize (`ref_resize.py`)
- `summarize_fixtures.py`: how far ref drifts from kiarina.
- `similarity_report.py`: cosine similarities in the replay stream (faces, objects, scenes), used
  to choose the tracker's thresholds.
- `frames_to_png.py`: the frames as lossless PNG for the app's assets (`mise run prepare`).
- `summarize_replay.py`: the readable part of an app replay report.

## Input

Shared assets of labs (`mise run //:test-assets:download`):

- stills: `jpg/many_face_1280x720_275kb.jpg`, `jpg/objects_1536x1024_358kb.jpg`, `jpg/street_scene_1774x887_287kb.jpg`
- the replay stream, one 768x512 "camera" at 2 fps (ffmpeg `fps=2`, scaled to fit and padded with black):
  `mp4/ltx2_dialogue_512x512_24fps_7s_355kb.mp4` 0-3.5 s (two people), `mp4/door_open_768x512_24fps_8s_302kb.mp4`,
  `jpg/many_face_1280x720_275kb.jpg` for 2 s, `mp4/glass_fall_768x512_24fps_8s_490kb.mp4`, and the dialogue clip again 3.5-7 s

The sha256 of every frame's RGB bytes is in `fixtures/input.json`; with another ffmpeg the PNG frames
may differ, which the Dart test detects (`frames are the ones the fixtures were made from`).

## Reproduce

Prerequisites: `uv`, `ffmpeg`, a kiarina-python checkout next to labs
(`~/src/github.com/kiarina/{labs,kiarina-python}`) at commit `9d483457`. From the lab directory:

```sh
uv run --project tools python tools/make_fixtures.py     # first run: kiarina downloads the models
uv run --project tools python tools/convert_yunet.py
uv run --project tools python tools/make_fixtures.py     # again, now with the converted YuNet
uv run --project tools python tools/summarize_fixtures.py
uv run --project tools python tools/similarity_report.py
```

`make_fixtures.py` exits asking for `convert_yunet.py` when the converted model is missing, after kiarina
has downloaded its models (so the first run is only for the download). Models go to
`models/kiarina-cache` (`KIARINA_UTILS_APP_USER_CACHE_DIR`, gitignored); kiarina verifies each sha256.

Versions (uv.lock): CPython 3.12.10, opencv-python 5.0.0 (with the KleidiCV HAL on arm64),
onnxruntime 1.31.0, numpy 2.5.4, onnx 1.23. Machine: macOS (Darwin 27), Apple silicon.
