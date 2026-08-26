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

- 2026/08
  - [Mage-VL real-time segment latency on Apple Silicon](2026/08/27/mage-vl-realtime-benchmark/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [streaming](tags/streaming.md), [video](tags/video.md), [benchmark](tags/benchmark.md)
  - [Does the Mage-VL streaming gate track event times, or content type?](2026/08/26/mage-vl-gate-event-correlation/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [streaming](tags/streaming.md), [video](tags/video.md), [apple-silicon](tags/apple-silicon.md)
  - [Mage-VL independent MLX port Stage 4: codec-native sparse video](2026/08/26/mage-vl-mlx-stage4-codec-native/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [video](tags/video.md), [streaming](tags/streaming.md), [docker](tags/docker.md)
  - [codec-video-prep aarch64 wheel on an ARM64 Linux container](2026/08/25/codec-video-prep-container/README.md) - [mage-vl](tags/mage-vl.md), [apple-silicon](tags/apple-silicon.md), [video](tags/video.md), [docker](tags/docker.md)
  - [Mage-VL parity fixture device comparison (CPU vs MPS)](2026/08/25/mage-vl-fixture-device/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [vlm](tags/vlm.md)
  - [Mage-VL image inference baseline on Mac: official PyTorch vs mlx-vlm](2026/08/25/mage-vl-image-baseline/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [vlm](tags/vlm.md), [quantization](tags/quantization.md)
  - [Mage-VL independent MLX port Stage 1: static image parity](2026/08/25/mage-vl-mlx-stage1-image-parity/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [vlm](tags/vlm.md)
  - [Mage-VL independent MLX port Stage 2: torch-free video parity](2026/08/25/mage-vl-mlx-stage2-video-parity/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [video](tags/video.md), [vlm](tags/vlm.md)
  - [Mage-VL independent MLX port Stage 3: proactive streaming gate](2026/08/25/mage-vl-mlx-stage3-streaming-gate/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [streaming](tags/streaming.md), [video](tags/video.md)
  - [Does the Mage-VL streaming gate detect events in real video?](2026/08/25/mage-vl-streaming-event-detection/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [streaming](tags/streaming.md), [video](tags/video.md), [apple-silicon](tags/apple-silicon.md)
  - [Mage-VL and MLX support status update (2026-08-24)](2026/08/24/mage-vl-mlx-update/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [video](tags/video.md), [streaming](tags/streaming.md)
  - [Mage-VL codec-native preprocessing portability on macOS](2026/08/05/mage-vl-codec-prep-portability/README.md) - [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [video](tags/video.md)
  - [Mage-VL on MLX and Apple Silicon](2026/08/05/mage-vl-mlx-mac/README.md) - [vlm](tags/vlm.md), [mage-vl](tags/mage-vl.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [video](tags/video.md), [streaming](tags/streaming.md), [quantization](tags/quantization.md)

- 2026/07
  - [LTX-2 dialogue video generation](2026/07/30/ltx2-dialogue-video/README.md) - [video](tags/video.md), [audio](tags/audio.md), [ltx-2](tags/ltx-2.md), [mlx](tags/mlx.md), [apple-silicon](tags/apple-silicon.md), [speech](tags/speech.md)
  - [Unreal mixed-audio auditory attention](2026/07/25/unreal-mixed-audio-attention/README.md) - [unreal-engine](tags/unreal-engine.md), [audio](tags/audio.md), [binaural](tags/binaural.md), [hrtf](tags/hrtf.md), [sound-localization](tags/sound-localization.md), [stft](tags/stft.md), [onset-detection](tags/onset-detection.md), [mcp](tags/mcp.md)
  - [Unreal Engine virtual-ear audio localization](2026/07/23/unreal-audio-localization/README.md) - [audio](tags/audio.md), [audio-mixer](tags/audio-mixer.md), [submix](tags/submix.md), [unreal-engine](tags/unreal-engine.md), [sound-localization](tags/sound-localization.md), [binaural](tags/binaural.md), [hrtf](tags/hrtf.md), [resonance-audio](tags/resonance-audio.md), [gcc](tags/gcc.md), [mcp](tags/mcp.md)
  - [ExecuTorch MLX Delegate with Qwen3 on Apple Silicon](2026/07/22/executorch-mlx-qwen3/README.md) - [llm](tags/llm.md), [executorch](tags/executorch.md), [mlx](tags/mlx.md), [qwen3](tags/qwen3.md), [apple-silicon](tags/apple-silicon.md), [quantization](tags/quantization.md), [benchmark](tags/benchmark.md)
  - [Laguna S 2.1 oQ2e on a 64 GB M1 Max](2026/07/22/laguna-s2-1-oQ2e-m1-max/README.md) - [llm](tags/llm.md), [mlx](tags/mlx.md), [laguna-s2-1](tags/laguna-s2-1.md), [apple-silicon](tags/apple-silicon.md), [quantization](tags/quantization.md), [benchmark](tags/benchmark.md)
  - [PyTorch 2.13 FlexAttention on MPS](2026/07/21/pytorch-2-13-flexattention-mps/README.md) - [pytorch](tags/pytorch.md), [flex-attention](tags/flex-attention.md), [mps](tags/mps.md), [apple-silicon](tags/apple-silicon.md), [benchmark](tags/benchmark.md)
  - [Apple SpeechAnalyzer Japanese streaming ASR](2026/07/20/apple-speech-analyzer-streaming-asr/README.md) - [audio](tags/audio.md), [asr](tags/asr.md), [speech-analyzer](tags/speech-analyzer.md), [streaming](tags/streaming.md), [apple-silicon](tags/apple-silicon.md), [swift](tags/swift.md)
  - [MeanVC streaming zero-shot voice conversion on Apple Silicon](2026/07/19/meanvc-streaming-apple-silicon/README.md) - [audio](tags/audio.md), [voice-conversion](tags/voice-conversion.md), [meanvc](tags/meanvc.md), [streaming](tags/streaming.md), [zero-shot](tags/zero-shot.md), [apple-silicon](tags/apple-silicon.md), [pytorch](tags/pytorch.md)
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
