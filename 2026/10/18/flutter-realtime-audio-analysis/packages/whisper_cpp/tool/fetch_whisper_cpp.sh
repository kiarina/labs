#!/usr/bin/env bash
# Downloads the pinned whisper.cpp release, verifies its sha256 and extracts it
# into third_party/whisper.cpp (gitignored). Run once before building.
#
#   packages/whisper_cpp/tool/fetch_whisper_cpp.sh
#
# Works on macOS, Linux and Git Bash on Windows (needs curl, tar and
# shasum or sha256sum).
set -euo pipefail

WHISPER_CPP_TAG="v1.9.5"
WHISPER_CPP_SHA256="ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720"
WHISPER_CPP_URL="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/${WHISPER_CPP_TAG}.tar.gz"

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${PKG_DIR}/third_party/whisper.cpp"
STAMP="${DEST}/.fetched-${WHISPER_CPP_TAG}"

if [[ -f "${STAMP}" ]]; then
  echo "whisper.cpp ${WHISPER_CPP_TAG} already present in third_party/whisper.cpp"
  exit 0
fi

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Downloading ${WHISPER_CPP_URL}"
curl -fsSL -o "${TMP}/whisper.cpp.tar.gz" "${WHISPER_CPP_URL}"

ACTUAL="$(sha256_of "${TMP}/whisper.cpp.tar.gz")"
if [[ "${ACTUAL}" != "${WHISPER_CPP_SHA256}" ]]; then
  echo "sha256 mismatch: expected ${WHISPER_CPP_SHA256}, got ${ACTUAL}" >&2
  exit 1
fi

mkdir -p "${TMP}/x"
tar -xzf "${TMP}/whisper.cpp.tar.gz" -C "${TMP}/x"
SRC="$(find "${TMP}/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"
mv "${SRC}" "${DEST}"
touch "${STAMP}"
echo "Extracted whisper.cpp ${WHISPER_CPP_TAG} to third_party/whisper.cpp"
