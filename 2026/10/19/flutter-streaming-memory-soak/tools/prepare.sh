#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mise run //:test-assets:download
mkdir -p app/assets work third_party
input=../../../../tests/assets/mp4/ltx2_dialogue_512x512_24fps_7s_355kb.mp4
ffmpeg -version | head -1 | grep -F '9.0.2' >/dev/null || { echo 'Fixture recipe pins FFmpeg 9.0.2' >&2; exit 1; }
printf '20e1c86950574d95ad72ed2d324407aa7e48d6013a5d556cdd9517fb71e412ff  %s\n' "$input" | shasum -a 256 -c -
# This is a derived test fixture, not newly generated visual content.
ffmpeg -v error -y -stream_loop -1 -i "$input" -t 600 -map 0:v:0 -map 0:a:0 -c copy -movflags +faststart app/assets/long.mp4
printf 'e5a96dbb5d648b119413b40da9475e2d406954c26e662add8742afa694856887  app/assets/long.mp4\n' | shasum -a 256 -c -
vad=app/assets/silero_vad.onnx
if [ ! -f "$vad" ]; then curl -fL https://raw.githubusercontent.com/snakers4/silero-vad/bfdc0193023f121ea5b3cc7b176dbed570a68a59/src/silero_vad/data/silero_vad.onnx -o "$vad"; fi
printf '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3  %s\n' "$vad" | shasum -a 256 -c -
shasum -a 256 "$input" app/assets/long.mp4 "$vad" > work/input-sha256.txt
ffprobe -v error -show_format -show_streams -of json app/assets/long.mp4 > work/input-probe.json
