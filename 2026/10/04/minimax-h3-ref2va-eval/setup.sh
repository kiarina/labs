#!/usr/bin/env bash
# Fetch the two engines at the versions measured here, and the model files.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p vendor prompts/guide
if [ ! -d vendor/h3c ]; then
  git clone https://github.com/antirez/h3.c vendor/h3c
  git -C vendor/h3c checkout 8974cc055ea9c02fcd14cc27dfda3e1027c05153
  make -C vendor/h3c -j8
fi
if [ ! -d vendor/mlx-serve ]; then
  gh release download v26.10.1 -R ddalcu/mlx-serve -p 'mlx-serve-bin-macos-arm64.tar.gz' -D vendor
  mkdir -p vendor/mlx-serve && tar xzf vendor/mlx-serve-bin-macos-arm64.tar.gz -C vendor/mlx-serve
  rm vendor/mlx-serve-bin-macos-arm64.tar.gz
fi
curl -sSfL -o prompts/guide/ref-en.txt \
  https://raw.githubusercontent.com/MiniMax-AI/MiniMax-H3/main/skills/h3-prompt-writing/references/ref-en.txt
hf download MiniMaxAI/MiniMax-H3 --include "Ref2VA/*" --include "model_index.json"
hf download ddalcu/MiniMax-H3-REF2VA-MLX-Serve-8bit
hf download lightx2v/Minimax-h3-Turbo minimax_h3_ref2v_turbo_8step_v1.0_768p_bf16.safetensors
