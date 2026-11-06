#!/usr/bin/env bash
# The probe in a Linux container (Docker's default bridge network), the
# signal and the echo peers on the host. Without STUN, as the app on a
# network of its own; then with STUN. Chrome gathering on its default-route
# interface only, then on every interface (ECHO_ALL_IFACES).
#   scripts/matrix-docker.sh <prefix> [REPS=3] [IMPLS="libdatachannel webrtc_dart"]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
prefix=$1 reps=${2:-3} impls=${3:-libdatachannel webrtc_dart}
export SIGNAL_FOR_PROBE=ws://host.docker.internal:8899
probe=(docker run --rm -v "$here/results:$here/results" dart-cli-webrtc-probe)
for ifaces in default all; do
for stun in none stun; do
  extra=$([ $stun = stun ] && echo "--stun stun:stun.cloudflare.com:3478" || true)
  for impl in $impls; do
    for echo_kind in chrome aiortc; do
      for role in offer answer; do
        for n in $(seq "$reps"); do
          # The aiortc echo gathers on every interface either way: run it once.
          [ "$echo_kind" = aiortc ] && [ "$ifaces" = default ] && continue
          ECHO_ALL_IFACES=$([ "$ifaces" = all ] && echo 1 || true) PROBE_ARGS="--impl $impl $extra" \
            "$here/run_pair.sh" "$echo_kind" "$role" close "$prefix-$ifaces-$stun-$impl-$echo_kind-$role-close-$n" "${probe[@]}" | head -1
        done
      done
    done
  done
done
done
python3 "$here/scripts/redact.py" "$here"/results/"$prefix"-*.json
