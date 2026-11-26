#!/usr/bin/env bash
# Sends the app's source, the media, the VRM and the scenes to the Windows PC
# (HOST, default kiarina@g-gear-2022) under %USERPROFILE%\work\sc.
set -euo pipefail
lab="$(cd "$(dirname "$0")/../.." && pwd)"
host="${HOST:-kiarina@g-gear-2022}"
media="$(cd "$lab/../../../../tests/assets" && pwd)"
dest='C:/Users/kiarina/work/sc'
ssh "$host" "if not exist C:\\Users\\kiarina\\work\\sc\\media mkdir C:\\Users\\kiarina\\work\\sc\\media C:\\Users\\kiarina\\work\\sc\\scenes C:\\Users\\kiarina\\work\\sc\\saved C:\\Users\\kiarina\\work\\sc\\logs C:\\Users\\kiarina\\work\\sc\\tools"
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
