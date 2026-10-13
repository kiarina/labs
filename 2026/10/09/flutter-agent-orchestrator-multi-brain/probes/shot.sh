#!/usr/bin/env bash
# Screenshots the window of an app started with probes/launch.sh, even when it is
# behind others: probes/shot.sh <label> -> $PROBE_DIR/<label>.png
set -euo pipefail
dir=${PROBE_DIR:-${TMPDIR:-/tmp}/orch-probe}
id=$(swift "$(dirname "$0")/window_id.swift" "$(cat "$dir/pids/$1")")
screencapture -x -o -l "$id" "$dir/$1.png" && echo "$dir/$1.png"
