#!/usr/bin/env bash
# Stage 2: 960x544, 124 frames (~5.2 s). mlx-serve (Turbo, then one base cross-check), then h3.c base.
# Expects mlx-serve already listening on 127.0.0.1:11234 with the REF2VA pack.
set -uo pipefail
cd "$(dirname "$0")"
export MLXSERVE_MODEL="${MLXSERVE_MODEL:?snapshot id of the mlx-serve REF2VA pack}"
export TURBO_LORA="${TURBO_LORA:?path to minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors}"
S="--size 960x544 --frames 124"

for c in "A_image raw" "A_image rewritten" "B_image_audio rewritten" "C_image_video rewritten" \
         "O_official rewritten" "B_image_audio raw" "C_image_video raw"; do
  set -- $c
  python3 run.py mlxserve "$1" $S --steps 8 --prompt "$2" --turbo
done
python3 run.py mlxserve O_official $S --steps 20 --prompt rewritten

kill "$(lsof -t -iTCP:11234 -sTCP:LISTEN)" 2>/dev/null
sleep 5

for c in "O_official rewritten" "A_image rewritten" "B_image_audio rewritten" "C_image_video rewritten"; do
  set -- $c
  python3 run.py h3c "$1" $S --steps 20 --prompt "$2"
done
echo STAGE2_DONE
