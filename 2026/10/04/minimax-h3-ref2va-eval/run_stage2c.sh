#!/usr/bin/env bash
# Stage 2 (multi-reference): rewrite prompts for D-G, then one Turbo run each on mlx-serve.
set -uo pipefail
cd "$(dirname "$0")"
export MLXSERVE_MODEL="${MLXSERVE_MODEL:?}" TURBO_LORA="${TURBO_LORA:?}"
S="--size 960x544 --frames 124"
while pgrep -f "run.py mlxserve" >/dev/null; do sleep 10; done
python3 rewrite_prompts.py D_multi_image E_multi_audio F_multi_video G_continuation
for c in G_continuation D_multi_image E_multi_audio F_multi_video; do
  python3 run.py mlxserve "$c" $S --steps 8 --prompt rewritten --turbo
done
echo STAGE2_DONE
