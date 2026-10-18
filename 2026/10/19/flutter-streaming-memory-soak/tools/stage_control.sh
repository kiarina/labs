#!/usr/bin/env bash
# Stage only after the app has initialized its sandbox container once.
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$HOME/Library/Containers/dev.lab.memorySoakLab/Data/Library/Application Support/dev.lab.memorySoakLab"
if [ ! -d "$stage" ]; then
 echo 'Run a one-pass idle app first to initialize its sandbox container.' >&2
 exit 1
fi
cp work/inference.pcm "$stage/inference.pcm"
