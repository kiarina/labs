#!/usr/bin/env bash
# Sends the app's source, the media, the VRM and the scenes to the Windows PC
# (HOST, an ssh destination with Windows' tar) under %USERPROFILE%\work\sc.
set -euo pipefail
lab="$(cd "$(dirname "$0")/../.." && pwd)"
host="${HOST:?set HOST to the Windows ssh destination}"
media="$(cd "$lab/../../../../tests/assets" && pwd)"
# The ssh session starts in the user's home: paths are relative to it.
dest='work/sc'
ssh "$host" "if not exist work\\sc\\media mkdir work\\sc\\media work\\sc\\scenes work\\sc\\saved work\\sc\\logs work\\sc\\tools"
export COPYFILE_DISABLE=1
tar -C "$lab" -czf - --exclude app/build --exclude app/.dart_tool --exclude app/ios --exclude app/android \
  --exclude app/macos --exclude 'app/windows/flutter/ephemeral' --exclude app/flutter_scene_generated app tools \
  | ssh "$host" "tar -xzf - -C $dest"
tar -C "$media" -czf - jpg mp3 mp4 | ssh "$host" "tar -xzf - -C $dest/media"
tar -C "$lab/work/assets/media" -czf - sounds | ssh "$host" "tar -xzf - -C $dest/media"
tar -C "$lab/work/assets" -czf - Seed-san.vrm test.vrma | ssh "$host" "tar -xzf - -C $dest"
tar -C "$lab/scenes" -czf - . | ssh "$host" "tar -xzf - -C $dest/scenes"
tar -C "$lab/work/scenes" -czf - . | ssh "$host" "tar -xzf - -C $dest/saved"
echo sent
