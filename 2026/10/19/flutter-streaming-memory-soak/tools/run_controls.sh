#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=app/build/macos/Build/Products/Release/memory_soak_lab.app/Contents/MacOS/memory_soak_lab
# Separate fresh processes. Controls are serialized; do not overlap primary timing runs.
tools/stage_control.sh
for mode in ${CONTROL_MODES:-idle decode infer}; do
 RUN_LABEL="control-$mode" RUN_MODE="$mode" MEDIA_SECONDS=600 PASSES="${CONTROL_PASSES:-8}" CLEAN_CALLBACKS=1 PCM_INPUT="$HOME/Library/Containers/dev.lab.memorySoakLab/Data/Library/Application Support/dev.lab.memorySoakLab/inference.pcm" RELIEVE_AT_END=1 "$app" > "work/control-$mode.log" 2>&1
done
