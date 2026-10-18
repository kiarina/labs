#!/usr/bin/env bash
# CMake compiler launcher for the single-threaded wasm build.
# whisper.cpp's CMakeLists.txt unconditionally appends -pthread under
# Emscripten; objects built that way use wasm atomics + shared memory and can
# only run where SharedArrayBuffer exists (cross-origin isolated pages).
# This launcher drops -pthread so the same sources link into a module that
# runs on any page.
args=()
for a in "$@"; do
  [[ "$a" == "-pthread" ]] && continue
  args+=("$a")
done
exec "${args[@]}"
