#!/usr/bin/env bash
# Runs the app's self-test on a physical iPhone / iPad (DEVICE=<udid>), which
# the Mac cannot reach on a port over Wi-Fi: builds a release with
# SELF_TEST=1, installs it, copies the media, VRM and scenes into the app's
# Documents/lab (devicectl), launches it, waits for done.txt and copies the
# results back to work/logs/ios-device.
set -euo pipefail
lab="$(cd "$(dirname "$0")/../.." && pwd)"
dev="${DEVICE:?set DEVICE to the device udid}"
bundle=dev.kiarina.labs.spiritCanvas
media="$(cd "$lab/../../../../tests/assets" && pwd)"
out="$lab/work/logs/ios-device"
mkdir -p "$out"
cd "$lab/app"
if [ "${SKIP_BUILD:-}" != 1 ]; then
  flutter build ios --release --dart-define=SELF_TEST=1 \
    --dart-define=MEDIA_DIR=@app/Documents/lab/media \
    --dart-define=SCENES_DIR=@app/Documents/lab/scenes \
    --dart-define=SAVED_SCENES_DIR=@app/Documents/lab/saved \
    --dart-define=VRM_PATH=@app/Documents/lab/Seed-san.vrm \
    --dart-define=VRMA_PATH=@app/Documents/lab/test.vrma \
    --dart-define=LOG_DIR=@app/Documents/lab/logs
fi
xcrun devicectl device install app --device "$dev" build/ios/iphoneos/Runner.app >/dev/null
put() { # put <local file> <path under Documents/lab>
  xcrun devicectl device copy to --device "$dev" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source "$1" --destination "Documents/lab/$2" >/dev/null
}
for f in "$media"/jpg/*.jpg; do put "$f" "media/jpg/$(basename "$f")"; done
for f in "$media"/mp4/*.mp4; do put "$f" "media/mp4/$(basename "$f")"; done
for f in "$media"/mp3/*.mp3; do put "$f" "media/mp3/$(basename "$f")"; done
for f in "$lab"/work/assets/media/sounds/*/*.wav; do put "$f" "media/sounds/$(basename "$(dirname "$f")")/$(basename "$f")"; done
put "$lab/work/assets/Seed-san.vrm" Seed-san.vrm
put "$lab/work/assets/test.vrma" test.vrma
for f in "$lab"/scenes/*.json; do put "$f" "scenes/$(basename "$f")"; done
for f in "$lab"/work/scenes/*.json; do put "$f" "saved/$(basename "$f")"; done
xcrun devicectl device process launch --device "$dev" --terminate-existing "$bundle" >/dev/null
get() { # get <path under Documents/lab> <local file>
  xcrun devicectl device copy from --device "$dev" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source "Documents/lab/$1" --destination "$2" >/dev/null 2>&1
}
for i in $(seq 1 60); do
  if get logs/done.txt "$out/done.txt"; then break; fi
  sleep 5
done
get logs/results.json "$out/results.json"
for n in 1-demo 2-layout 3-behaviors 4-web 5-space-station-escape 5-mole-garden 5-today-planner 5-today-planner-ticked; do
  get "logs/$n.png" "$out/$n.png" || echo "missing $n.png"
done
ls "$out"
