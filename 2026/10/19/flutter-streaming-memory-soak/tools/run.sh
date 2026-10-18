#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
mode="${BUILD_MODE:-release}"
(cd app && flutter build macos --"$mode" > ../work/build-"$mode".log 2>&1)
case "$mode" in release) product=Release;;profile) product=Profile;;debug) product=Debug;;esac
exec app/build/macos/Build/Products/"$product"/memory_soak_lab.app/Contents/MacOS/memory_soak_lab
