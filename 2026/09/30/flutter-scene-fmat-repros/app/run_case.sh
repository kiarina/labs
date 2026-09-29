#!/usr/bin/env bash
# Runs the built macOS debug app once per case and prints its report.
# Build first: flutter build macos --debug
# Usage: ./run_case.sh A B C ...   (MODEL=/abs/path.vrm to swap the skinned model,
#        SHADOW=1 for a shadow-casting light, PRELOAD=<dylib> to force safe math)
set -u
app=build/macos/Build/Products/Debug/fmat_repro.app/Contents/MacOS/fmat_repro
reports=~/Library/Logs/DiagnosticReports
log=$(mktemp)
for c in "$@"; do
  before=$(ls -t "$reports"/fmat_repro-*.ips 2>/dev/null | head -1)
  (
    # Exported in this shell, not passed through env(1): SIP strips DYLD_*
    # when a protected binary is exec'd.
    [[ -n "${PRELOAD:-}" ]] && export DYLD_INSERT_LIBRARIES=$PRELOAD SAFEMATH=1
    CASES=$c OUT="fmat_$c.png" EXIT=1 exec "$app"
  ) >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 60); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  kill $pid 2>/dev/null && echo "timeout" >>"$log"
  wait $pid 2>/dev/null
  status=$?
  sleep 4 # crash reports land a few seconds after the process dies
  after=$(ls -t "$reports"/fmat_repro-*.ips 2>/dev/null | head -1)
  line=$(grep -E "\[repro\] [A-J] " "$log" | sed 's/^flutter: //')
  err=$(grep -oE "Could not create render pipeline.*\(thread" "$log" | head -1)
  crash=""
  [[ -n "$after" && "$after" != "$before" ]] && crash="CRASH ($(basename "$after"))"
  echo "case $c: ${line:-no report} ${err:+| $err} ${crash:+| $crash} (exit $status)"
done
rm -f "$log"
