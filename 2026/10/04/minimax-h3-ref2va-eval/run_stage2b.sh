#!/usr/bin/env bash
# Stage 2 (trimmed): one Turbo run per reference pattern, then h3.c base on the official case and the voice case.
set -uo pipefail
cd "$(dirname "$0")"
export MLXSERVE_MODEL="${MLXSERVE_MODEL:?}" TURBO_LORA="${TURBO_LORA:?}"
S="--size 960x544 --frames 124"
while pgrep -f "run.py mlxserve" >/dev/null; do sleep 10; done
for c in B_image_audio C_image_video O_official; do
  python3 run.py mlxserve "$c" $S --steps 8 --prompt rewritten --turbo
done
kill "$(lsof -t -iTCP:11234 -sTCP:LISTEN)" 2>/dev/null
while lsof -t -iTCP:11234 -sTCP:LISTEN >/dev/null; do sleep 5; done
for c in O_official B_image_audio; do
  python3 run.py h3c "$c" $S --steps 20 --prompt rewritten
done
echo STAGE2_DONE
