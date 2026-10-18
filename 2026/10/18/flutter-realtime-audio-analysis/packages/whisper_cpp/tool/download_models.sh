#!/usr/bin/env bash
# Downloads ggml Whisper models from Hugging Face into the lab's gitignored
# models/whisper/ and verifies each sha256 against the LFS oid listed at
# https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main
#
#   packages/whisper_cpp/tool/download_models.sh [base] [small] [medium]
#
# Default: base small medium.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${PKG_DIR}/../../models/whisper"
BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

sha_for() {
  case "$1" in
    base)   echo "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe" ;;  # 147951465 B
    small)  echo "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b" ;;  # 487601967 B
    medium) echo "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208" ;;  # 1533763059 B
    *) echo "unknown model: $1" >&2; exit 1 ;;
  esac
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

mkdir -p "${DEST}"
MODELS=("$@")
if [[ ${#MODELS[@]} -eq 0 ]]; then MODELS=(base small medium); fi

for m in "${MODELS[@]}"; do
  want="$(sha_for "$m")"
  file="${DEST}/ggml-${m}.bin"
  if [[ -f "${file}" ]] && [[ "$(sha256_of "${file}")" == "${want}" ]]; then
    echo "ok   ggml-${m}.bin"
    continue
  fi
  echo "get  ggml-${m}.bin"
  curl -fL --retry 3 -o "${file}.part" "${BASE_URL}/ggml-${m}.bin"
  got="$(sha256_of "${file}.part")"
  if [[ "${got}" != "${want}" ]]; then
    echo "sha256 mismatch for ggml-${m}.bin: expected ${want}, got ${got}" >&2
    exit 1
  fi
  mv "${file}.part" "${file}"
  echo "ok   ggml-${m}.bin"
done
