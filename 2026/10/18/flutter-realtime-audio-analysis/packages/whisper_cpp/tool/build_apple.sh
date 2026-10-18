#!/usr/bin/env bash
# Builds whisper.cpp + ggml (Metal with embedded shaders, Accelerate/BLAS) as
# one static library for the current Xcode platform/arch, using whisper.cpp's
# own CMake. Called from the CocoaPods script phase in macos/ and ios/
# whisper_cpp.podspec with the output directory as $1; reads PLATFORM_NAME,
# ARCHS and *_DEPLOYMENT_TARGET from the Xcode build environment.
#
# Output: $1/lib/libwhisper_all.a
#
# Manual use (outside Xcode):
#   PLATFORM_NAME=macosx ARCHS=arm64 MACOSX_DEPLOYMENT_TARGET=14.0 \
#     tool/build_apple.sh /tmp/whisper_cmake
set -euo pipefail

OUT="${1:?usage: build_apple.sh <out-dir>}"
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLATFORM_NAME="${PLATFORM_NAME:-macosx}"
ARCHS="${ARCHS:-$(uname -m)}"

if [[ ! -f "${PKG_DIR}/third_party/whisper.cpp/include/whisper.h" ]]; then
  echo "error: whisper.cpp sources missing. Run packages/whisper_cpp/tool/fetch_whisper_cpp.sh" >&2
  exit 1
fi

# Xcode script phases do not see Homebrew's PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
CMAKE="$(command -v cmake || true)"
if [[ -z "${CMAKE}" ]]; then
  echo "error: cmake not found (brew install cmake)" >&2
  exit 1
fi

case "${PLATFORM_NAME}" in
  macosx)
    PLATFORM_ARGS=(-DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}")
    ;;
  iphoneos | iphonesimulator)
    PLATFORM_ARGS=(
      -DCMAKE_SYSTEM_NAME=iOS
      -DCMAKE_OSX_SYSROOT="${PLATFORM_NAME}"
      -DCMAKE_OSX_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.6}"
    )
    ;;
  *)
    echo "error: unsupported PLATFORM_NAME=${PLATFORM_NAME}" >&2
    exit 1
    ;;
esac

ARCH_LIST="$(echo "${ARCHS}" | xargs | tr ' ' ';')"
BUILD_DIR="${OUT}/build"
mkdir -p "${BUILD_DIR}" "${OUT}/lib"

# Run CMake with a clean environment: Xcode exports SDKROOT, *_DEPLOYMENT_TARGET,
# ARCHS etc., which would leak into the host-side compiler checks.
CLEAN_ENV=(env -i "HOME=${HOME}" "PATH=${PATH}" "TMPDIR=${TMPDIR:-/tmp}")
if [[ -n "${DEVELOPER_DIR:-}" ]]; then CLEAN_ENV+=("DEVELOPER_DIR=${DEVELOPER_DIR}"); fi

"${CLEAN_ENV[@]}" "${CMAKE}" -S "${PKG_DIR}/src" -B "${BUILD_DIR}" \
  -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWCPP_APPLE_STATIC_ONLY=ON \
  -DCMAKE_OSX_ARCHITECTURES="${ARCH_LIST}" \
  "${PLATFORM_ARGS[@]}" >"${OUT}/cmake-configure.log" 2>&1 \
  || { cat "${OUT}/cmake-configure.log" >&2; exit 1; }

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
"${CLEAN_ENV[@]}" "${CMAKE}" --build "${BUILD_DIR}" --target wcpp_static_deps -j "${JOBS}" \
  >"${OUT}/cmake-build.log" 2>&1 \
  || { tail -n 80 "${OUT}/cmake-build.log" >&2; exit 1; }

LIBS=()
while IFS= read -r f; do LIBS+=("$f"); done < <(find "${BUILD_DIR}" -name '*.a' -not -name 'libwhisper_all.a' | sort)
NEW="${OUT}/lib/libwhisper_all.a.new"
xcrun libtool -static -no_warning_for_no_symbols -o "${NEW}" "${LIBS[@]}"
# Only touch the archive when it changed, so Xcode does not relink needlessly.
if ! cmp -s "${NEW}" "${OUT}/lib/libwhisper_all.a"; then
  mv "${NEW}" "${OUT}/lib/libwhisper_all.a"
else
  rm -f "${NEW}"
fi
echo "whisper.cpp static library: ${OUT}/lib/libwhisper_all.a (${PLATFORM_NAME} ${ARCHS})"
