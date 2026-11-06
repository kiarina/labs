#!/usr/bin/env bash
# One session: signal + echo peer + the Dart probe.
#   ./run_pair.sh <chrome|aiortc> <probe-role offer|answer> <end close|kill> <label> [probe command...]
# The probe command defaults to `dart run bin/probe.dart` (JIT). Its signal
# URL is SIGNAL_FOR_PROBE (default ws://127.0.0.1:8899): a container uses
# ws://host.docker.internal:8899.
set -u
export LDC_DIR=${LDC_DIR:-$(cd "$(dirname "$0")" && pwd)/build/libdatachannel/out}
here=$(cd "$(dirname "$0")" && pwd)
echo_kind=$1 role=$2 end=$3 label=$4; shift 4
probe=("$@"); [ ${#probe[@]} -eq 0 ] && probe=(dart run bin/probe.dart)
echo_role=$([ "$role" = offer ] && echo answer || echo offer)
logs=$here/build/logs; mkdir -p "$logs" "$here/results"
(cd "$here/dart" && exec dart run bin/signal.dart 8899) > "$logs/$label.signal.log" 2>&1 &
sig=$!
for _ in $(seq 50); do curl -s -o /dev/null localhost:8899 && break; sleep 0.2; done
case $echo_kind in
  chrome) (cd "$here/peers/browser" && exec node run.mjs ws://127.0.0.1:8899 "$echo_role") > "$logs/$label.echo.log" 2>&1 & ;;
  aiortc) (cd "$here/peers/aiortc" && exec uv run echo.py ws://127.0.0.1:8899 "$echo_role") > "$logs/$label.echo.log" 2>&1 & ;;
esac
peer=$!
(cd "$here/dart" && "${probe[@]}" --signal "${SIGNAL_FOR_PROBE:-ws://127.0.0.1:8899}" --role "$role" --end "$end" \
  --label "$label" --out "$here/results/$label.json" ${PROBE_ARGS:-}) > "$logs/$label.probe.log" 2>&1
rc=$?
curl -s -o /dev/null localhost:8899/stop
# The Chrome driver can ignore SIGTERM after a failed session; don't wait on it.
sleep 2; kill $peer $sig 2>/dev/null; sleep 1; pkill -9 -P $peer 2>/dev/null; kill -9 $peer $sig 2>/dev/null
wait 2>/dev/null
echo "$label rc=$rc"; grep -E "ok=|error|Exception" "$logs/$label.probe.log" | head -3
