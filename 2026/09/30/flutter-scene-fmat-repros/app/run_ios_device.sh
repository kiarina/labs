#!/usr/bin/env bash
# Builds the app in release for a connected iOS device, runs it once, and
# prints its report (copied off the device: a release build has no console).
#
#   DEVICE=<udid> CASES=ABCDEFGHIJ [SHADOW=1] [MODEL=models/<file in models/>] ./run_ios_device.sh
set -euo pipefail
: "${DEVICE:?set DEVICE to the device UDID (xcrun devicectl list devices)}"
BUNDLE=dev.kiarina.fmatRepro
out="$(mktemp -d)"
# The app echoes this, so an older report left on the device is not mistaken
# for this run's.
run_id="$(date +%s)-$RANDOM"
flutter build ios --release --dart-define=CASES="${CASES:-ABCDEFGHIJ}" \
  --dart-define=SHADOW="${SHADOW:-0}" --dart-define=MODEL="${MODEL:-models/CesiumMan.glb}" --dart-define=EXIT=1 --dart-define=RUN_ID="$run_id" >"$out/build.log" 2>&1 \
  || { tail -20 "$out/build.log"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/ios/iphoneos/Runner.app >/dev/null
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
for _ in $(seq 1 40); do
  sleep 3
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source tmp/fmat_report.txt \
      --destination "$out/report.txt" >/dev/null 2>&1 && grep -q "run $run_id" "$out/report.txt" \
      && grep -q "done" "$out/report.txt"; then
    break
  fi
done
if grep -q "run $run_id" "$out/report.txt" 2>/dev/null; then
  cat "$out/report.txt"
  grep -q "done" "$out/report.txt" || echo "(no 'done' line: the app may have crashed)"
else
  echo "no report from this run (the app may have crashed before it was ready)"
fi
rm -rf "$out"
