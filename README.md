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
  - [SFace face embedding dataset comparison](2026/07/10/sface-face-embedding/README.md) - [image](tags/image.md), [embedding](tags/embedding.md), [face](tags/face.md), [sface](tags/sface.md), [opencv](tags/opencv.md)
  - [D-FINE Object Detection](2026/07/09/dfine-object-detection/README.md) - [image](tags/image.md), [detection](tags/detection.md), [onnx](tags/onnx.md), [dfine](tags/dfine.md), [object-detection](tags/object-detection.md)
  - [YuNet Face Detection](2026/07/08/yunet-face-detection/README.md) - [image](tags/image.md), [detection](tags/detection.md), [yunet](tags/yunet.md), [face](tags/face.md)
  - [YAMNet audio tagging on ESC-50](2026/07/07/yamnet-esc50-audio-tagging/README.md) - [audio](tags/audio.md), [yamnet](tags/yamnet.md), [tflite](tags/tflite.md), [audio-tagging](tags/audio-tagging.md), [esc-50](tags/esc-50.md)
  - [CLAP ONNX environmental sound grouping with ESC-50](2026/07/06/clap-onnx-esc50/README.md) - [audio](tags/audio.md), [clap](tags/clap.md), [onnx](tags/onnx.md), [embedding](tags/embedding.md), [esc-50](tags/esc-50.md)
  - [ECAPA-TDNN ONNX speaker grouping](2026/07/05/ecapa-tdnn-onnx/README.md) - [audio](tags/audio.md), [ecapa-tdnn](tags/ecapa-tdnn.md), [onnx](tags/onnx.md), [speaker-embedding](tags/speaker-embedding.md)
  - [Pyannote SCD speaker segmentation](2026/07/04/pyannote-scd/README.md) - [audio](tags/audio.md), [onnx](tags/onnx.md), [pyannote](tags/pyannote.md), [speaker-change-detection](tags/speaker-change-detection.md)
  - [Silero VAD speech segment extraction](2026/07/03/silero-vad/README.md) - [audio](tags/audio.md), [onnx](tags/onnx.md), [silero-vad](tags/silero-vad.md)
