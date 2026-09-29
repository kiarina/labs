#!/bin/bash
# Compiles flutter_scene_standard.frag at the current commit of a flutter_scene
# checkout to MSL with impellerc, then builds a pipeline from it.
# Exit 0 = compiles, 1 = the compiler service crashes, 125 = cannot tell.
# Usable as `git bisect run`. Needs FLUTTER_ROOT and LAB (this directory).
set -u
engine="$FLUTTER_ROOT/bin/cache/artifacts/engine/darwin-x64"
cd "$(git rev-parse --show-toplevel)/packages/flutter_scene" || exit 125
out="$LAB/out/standard_$(git rev-parse --short HEAD).metal"
mkdir -p "$LAB/out"
"$engine/impellerc" --metal-desktop --input=shaders/flutter_scene_standard.frag \
  --sl="$out" --spirv="$out.spv" --input-type=frag \
  --include=shaders --include="$engine/shader_lib" >/dev/null 2>&1 || exit 125
result=$("$LAB/probe/probe" "$out" 2>&1 | tail -1)
echo "$(git rev-parse --short HEAD) $result" | cut -c1-120
case "$result" in
  *XPC_ERROR_CONNECTION_INTERRUPTED*) exit 1 ;;
  ok) exit 0 ;;
  *) exit 125 ;;
esac
