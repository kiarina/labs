# labs

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Small, independent projects for experiments, research, and investigations.

## Check out a lab

Use a shallow, partial clone with sparse checkout to fetch only one lab and
the shared tasks:

```sh
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/kiarina/labs.git
cd labs
git sparse-checkout set .gitignore .mise/tasks Makefile mise.toml YYYY/MM/DD/{slug}
```

## Labs

- 2026/07
  - [MediaPipe Holistic real-time VRM retargeting](2026/07/18/mediapipe-holistic-vrm/README.md) - [image](tags/image.md), [pose-estimation](tags/pose-estimation.md), [mediapipe](tags/mediapipe.md), [vrm](tags/vrm.md), [three-js](tags/three-js.md), [streaming](tags/streaming.md)
  - [YAMNet streaming acoustic novelty detection](2026/07/17/yamnet-streaming-novelty/README.md) - [audio](tags/audio.md), [yamnet](tags/yamnet.md), [anomaly-detection](tags/anomaly-detection.md), [streaming](tags/streaming.md), [tensorflow](tags/tensorflow.md), [esc-50](tags/esc-50.md)
  - [MoGe-2 surface normals on Apple Silicon](2026/07/16/moge2-surface-normal-apple-silicon/README.md) - [image](tags/image.md), [surface-normal](tags/surface-normal.md), [depth-estimation](tags/depth-estimation.md), [moge-2](tags/moge-2.md), [apple-silicon](tags/apple-silicon.md), [mps](tags/mps.md)
  - [ZipDepth on Apple Silicon](2026/07/15/zipdepth-apple-silicon/README.md) - [image](tags/image.md), [depth-estimation](tags/depth-estimation.md), [zipdepth](tags/zipdepth.md), [onnx](tags/onnx.md), [apple-silicon](tags/apple-silicon.md)
  - [YOLO26 semantic segmentation on Apple Silicon](2026/07/14/yolo26-semantic-segmentation/README.md) - [image](tags/image.md), [semantic-segmentation](tags/semantic-segmentation.md), [yolo26](tags/yolo26.md), [onnx](tags/onnx.md), [onnx-runtime](tags/onnx-runtime.md)
  - [BiRefNet ONNX background removal](2026/07/13/birefnet-onnx/README.md) - [image](tags/image.md), [background-removal](tags/background-removal.md), [onnx](tags/onnx.md), [birefnet](tags/birefnet.md), [onnx-runtime](tags/onnx-runtime.md)
  - [PP-OCRv6-small with RapidOCR](2026/07/12/pp-ocrv6-small-rapidocr/README.md) - [image](tags/image.md), [ocr](tags/ocr.md), [onnx](tags/onnx.md), [pp-ocrv6](tags/pp-ocrv6.md), [rapidocr](tags/rapidocr.md)
  - [AniGen on Apple Silicon](2026/07/11/anigen-mac/README.md) - [image](tags/image.md), [3d](tags/3d.md), [animation](tags/animation.md), [anigen](tags/anigen.md), [apple-silicon](tags/apple-silicon.md), [mps](tags/mps.md)
  - [SFace face embedding dataset comparison](2026/07/10/sface-face-embedding/README.md) - [image](tags/image.md), [embedding](tags/embedding.md), [face](tags/face.md), [sface](tags/sface.md), [opencv](tags/opencv.md)
  - [D-FINE Object Detection](2026/07/09/dfine-object-detection/README.md) - [image](tags/image.md), [detection](tags/detection.md), [onnx](tags/onnx.md), [dfine](tags/dfine.md), [object-detection](tags/object-detection.md)
  - [YuNet Face Detection](2026/07/08/yunet-face-detection/README.md) - [image](tags/image.md), [detection](tags/detection.md), [yunet](tags/yunet.md), [face](tags/face.md)
  - [YAMNet audio tagging on ESC-50](2026/07/07/yamnet-esc50-audio-tagging/README.md) - [audio](tags/audio.md), [yamnet](tags/yamnet.md), [tflite](tags/tflite.md), [audio-tagging](tags/audio-tagging.md), [esc-50](tags/esc-50.md)
  - [CLAP ONNX environmental sound grouping with ESC-50](2026/07/06/clap-onnx-esc50/README.md) - [audio](tags/audio.md), [clap](tags/clap.md), [onnx](tags/onnx.md), [embedding](tags/embedding.md), [esc-50](tags/esc-50.md)
  - [ECAPA-TDNN ONNX speaker grouping](2026/07/05/ecapa-tdnn-onnx/README.md) - [audio](tags/audio.md), [ecapa-tdnn](tags/ecapa-tdnn.md), [onnx](tags/onnx.md), [speaker-embedding](tags/speaker-embedding.md)
  - [Pyannote SCD speaker segmentation](2026/07/04/pyannote-scd/README.md) - [audio](tags/audio.md), [onnx](tags/onnx.md), [pyannote](tags/pyannote.md), [speaker-change-detection](tags/speaker-change-detection.md)
  - [Silero VAD speech segment extraction](2026/07/03/silero-vad/README.md) - [audio](tags/audio.md), [onnx](tags/onnx.md), [silero-vad](tags/silero-vad.md)
