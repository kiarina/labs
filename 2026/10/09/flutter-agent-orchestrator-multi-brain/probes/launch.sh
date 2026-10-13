#!/usr/bin/env bash
# Starts one copy of the app (already built: `cd app && flutter build macos --debug`)
# with its own state folder, and records its PID, for checks with several apps on
# one Mac. Stop it with `kill $(cat "$PROBE_DIR/pids/<label>")`, never by guessing.
#
#   probes/launch.sh <label> [VAR=value ...]   e.g. ORCH_BRAINS=brain-a ORCH_ROLE=body,signal
#
# PROBE_DIR (default $TMPDIR/orch-probe) holds pids/<label> and state/<label>.
set -euo pipefail
label=$1; shift
dir=${PROBE_DIR:-${TMPDIR:-/tmp}/orch-probe}
cd "$(dirname "$0")/.."
args=(--env "CLAUDE_FLUTTER_SIDECAR=$PWD/sidecar" --env "NODE_BIN=$(command -v node)" --env "ORCH_STATE_DIR=$dir/state/$label")
for kv in "$@"; do args+=(--env "$kv"); done
mkdir -p "$dir/pids" "$dir/state/$label"
before=$(pgrep -x agent_orchestrator || true)
# An empty environment, as Finder starts apps (see .mise/tasks/run).
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  open -n "${args[@]}" app/build/macos/Build/Products/Debug/agent_orchestrator.app
for _ in $(seq 50); do
  for p in $(pgrep -x agent_orchestrator || true); do
    if ! grep -qx "$p" <<<"$before"; then echo "$p" > "$dir/pids/$label"; echo "$label pid $p"; exit 0; fi
  done
  sleep 0.2
done
echo "no new pid" >&2; exit 1
