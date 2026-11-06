#!/usr/bin/env bash
# Every implementation × echo peer × probe role, REPS times with a polite
# close and once with a kill, using the AOT probe. Results go to
# results/<prefix>-<impl>-<echo>-<role>-<end>-<n>.json.
#   scripts/matrix.sh <prefix> [REPS=3]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
prefix=$1 reps=${2:-3}
mkdir -p "$here/build"
(cd "$here/dart" && dart compile exe bin/probe.dart -o "$here/build/probe" >/dev/null)
for impl in webrtc_dart libdatachannel; do
  for echo_kind in chrome aiortc; do
    for role in offer answer; do
      for n in $(seq "$reps"); do
        PROBE_ARGS="--impl $impl" "$here/run_pair.sh" "$echo_kind" "$role" close "$prefix-$impl-$echo_kind-$role-close-$n" "$here/build/probe" | head -1
      done
      PROBE_ARGS="--impl $impl" "$here/run_pair.sh" "$echo_kind" "$role" kill "$prefix-$impl-$echo_kind-$role-kill-1" "$here/build/probe" | head -1
    done
  done
done
python3 "$here/scripts/redact.py" "$here"/results/"$prefix"-*.json
