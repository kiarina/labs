#!/usr/bin/env bash
# Builds whisper.cpp for the browser (WebAssembly, SIMD128) and stages the
# files the Flutter web backend (lib/src/whisper_web.dart) loads at runtime:
#
#   assets/whisper_web/whisper_worker.js  (copied from web/)
#   assets/whisper_web/whisper_st.js/.wasm  single-threaded, runs anywhere
#   assets/whisper_web/whisper_mt.js/.wasm  pthreads, needs crossOriginIsolated
#
# Everything in assets/whisper_web/ except its .gitignore is a build output.
#
#   packages/whisper_cpp/tool/build_web.sh            # both variants
#   VARIANTS=st packages/whisper_cpp/tool/build_web.sh
#
# EMSCRIPTEN_SYSTEM_PROCESSOR=wasm32 matters: Emscripten's toolchain file
# reports "x86" by default, which ggml does not recognise, so ggml-cpu would
# fall back to GGML_CPU_GENERIC and skip its wasm SIMD kernels.
#
# Needs Emscripten (emcc/emcmake on PATH; `brew install emscripten` on macOS)
# and CMake. Fetches whisper.cpp via tool/fetch_whisper_cpp.sh if missing.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${PKG_DIR}/third_party/whisper.cpp"
BUILD_ROOT="${PKG_DIR}/build/web"
OUT_DIR="${PKG_DIR}/assets/whisper_web"
VARIANTS="${VARIANTS:-st mt}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

command -v emcc >/dev/null || { echo "emcc not found (install Emscripten)" >&2; exit 1; }
[[ -d "${WHISPER_DIR}" ]] || "${PKG_DIR}/tool/fetch_whisper_cpp.sh"

echo "emcc: $(emcc --version 2>/dev/null | head -n 1)"
mkdir -p "${OUT_DIR}"

EXPORTS='_malloc,_free,_wjs_set_log_level,_wjs_system_info,_wjs_init,_wjs_free,_wjs_full,_wjs_n_segments,_wjs_segment_text,_wjs_segment_t0,_wjs_segment_t1,_wjs_lang'

build_variant() {
  local v="$1" bdir="${BUILD_ROOT}/$1"
  local cmake_extra=() link_extra=()
  if [[ "$v" == "st" ]]; then
    cmake_extra=(
      -DCMAKE_C_COMPILER_LAUNCHER="${PKG_DIR}/web/strip_pthread_launcher.sh"
      -DCMAKE_CXX_COMPILER_LAUNCHER="${PKG_DIR}/web/strip_pthread_launcher.sh"
    )
  else
    # The worker that hosts the module blocks inside whisper_full, so it
    # cannot spawn pthread Workers on demand: pre-spawn the pool at startup.
    # The size is chosen by whisper_worker.js (Module.wjsPoolSize).
    link_extra=(-pthread '-sPTHREAD_POOL_SIZE=Module.wjsPoolSize||4' -sPTHREAD_POOL_SIZE_STRICT=2)
  fi

  emcmake cmake -S "${WHISPER_DIR}" -B "${bdir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_SDL2=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF \
    -DEMSCRIPTEN_SYSTEM_PROCESSOR=wasm32 \
    ${cmake_extra[@]+"${cmake_extra[@]}"} >/dev/null
  cmake --build "${bdir}" --target whisper -j "${JOBS}" >/dev/null

  local libs
  libs=$(find "${bdir}" -name '*.a' | sort)
  # shellcheck disable=SC2086
  em++ -O3 -msimd128 -std=c++17 \
    -I "${WHISPER_DIR}/include" -I "${WHISPER_DIR}/ggml/include" \
    "${PKG_DIR}/web/whisper_wasm.cpp" ${libs} ${libs} \
    -o "${OUT_DIR}/whisper_${v}.js" \
    -sMODULARIZE=1 -sEXPORT_NAME=createWhisperModule \
    -sENVIRONMENT=worker \
    -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -sMAXIMUM_MEMORY=4GB \
    -sSTACK_SIZE=5MB \
    -sEXPORTED_FUNCTIONS="${EXPORTS}" \
    -sEXPORTED_RUNTIME_METHODS=HEAPU8,wasmMemory,UTF8ToString,stringToNewUTF8 \
    ${link_extra[@]+"${link_extra[@]}"}
  ls -l "${OUT_DIR}/whisper_${v}".*
}

for v in ${VARIANTS}; do build_variant "$v"; done

cp "${PKG_DIR}/web/whisper_worker.js" "${OUT_DIR}/whisper_worker.js"
printf '%s\n' '# Build outputs of tool/build_web.sh' '*' '!.gitignore' > "${OUT_DIR}/.gitignore"
echo "Staged web runtime in assets/whisper_web/"
