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
git sparse-checkout set .gitignore .mise/tasks YYYY/MM/DD/{slug}
```

## audio

- [Silero VAD speech segment extraction](2026/07/03/silero-vad/README.md)

## onnx

- [Silero VAD speech segment extraction](2026/07/03/silero-vad/README.md)

## silero-vad

- [Silero VAD speech segment extraction](2026/07/03/silero-vad/README.md)
