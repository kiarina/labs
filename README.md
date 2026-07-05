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
  - [Pyannote SCD speaker segmentation](2026/07/04/pyannote-scd/README.md) - [audio](tags/audio.md), [onnx](tags/onnx.md), [pyannote](tags/pyannote.md), [speaker-change-detection](tags/speaker-change-detection.md)
  - [Silero VAD speech segment extraction](2026/07/03/silero-vad/README.md) - [audio](tags/audio.md), [onnx](tags/onnx.md), [silero-vad](tags/silero-vad.md)
