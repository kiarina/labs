#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mise run //:test-assets:download
mkdir -p app/assets work
cp ../../../../tests/assets/mp4/ltx2_dialogue_512x512_24fps_7s_355kb.mp4 app/assets/input.mp4
vad=app/assets/silero_vad.onnx
if [ ! -f "$vad" ]; then
 curl -fL --retry 2 https://raw.githubusercontent.com/snakers4/silero-vad/bfdc0193023f121ea5b3cc7b176dbed570a68a59/src/silero_vad/data/silero_vad.onnx -o "$vad"
fi
printf '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3  %s\n' "$vad" | shasum -a 256 -c -
shasum -a 256 app/assets/input.mp4 app/assets/silero_vad.onnx > work/input-sha256.txt
