#!/usr/bin/env bash
# Builds the app in release for a connected iOS device, runs it once, and
# prints its report (copied off the device: a release build has no console).
#
#   DEVICE=<udid> CASES=ABCDEFGHIJ [SHADOW=1] ./run_ios_device.sh
set -euo pipefail
: "${DEVICE:?set DEVICE to the device UDID (xcrun devicectl list devices)}"
BUNDLE=dev.kiarina.fmatRepro
out="$(mktemp -d)"
flutter build ios --release --dart-define=CASES="${CASES:-ABCDEFGHIJ}" \
  --dart-define=SHADOW="${SHADOW:-0}" --dart-define=EXIT=1 >"$out/build.log" 2>&1 \
  || { tail -20 "$out/build.log"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/ios/iphoneos/Runner.app >/dev/null
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
for _ in $(seq 1 40); do
  sleep 3
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source tmp/fmat_report.txt \
      --destination "$out/report.txt" >/dev/null 2>&1 && grep -q "done" "$out/report.txt"; then
    break
  fi
done
cat "$out/report.txt" 2>/dev/null || echo "no report (the app may have crashed)"
rm -rf "$out"
