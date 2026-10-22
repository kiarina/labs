"""Fetch the pinned weights and binaries.

- qwentts.cpp GGUFs (Serveurperso/Qwen3-TTS-GGUF): talkers by size and quantization, plus the 12 Hz codec.
- llama.cpp's official Qwen3-TTS GGUF (ggml-org) and llama.cpp's release binaries (macOS arm64, Windows CUDA 13.4).
- The baselines: MLX bf16 (Mac) and the pltobing ONNX port (Windows).

Usage: uv run download.py [--talkers 1.7b-base-Q8_0 ...] [--llama]
"""

from __future__ import annotations

import argparse
import io
import platform
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

from huggingface_hub import hf_hub_download, snapshot_download

LAB_DIR = Path(__file__).resolve().parent
QWENTTS_GGUF = ("Serveurperso/Qwen3-TTS-GGUF", "b7ee2e8c7459c3bea99da23e3d178125a7d1713c")
QWENTTS_CODEC = "qwen-tokenizer-12hz-F32.gguf"  # the RVQ paths stay F32 in every variant; F32 is what models.sh fetches
LLAMA_GGUF = ("ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF", "ca27d74bc954b73dadab5b71ca265d87fc861a7c")
LLAMA_RELEASE = "b11827"
LLAMA_ASSETS = {
    "Darwin": [f"llama-{LLAMA_RELEASE}-bin-macos-arm64.tar.gz"],
    "Windows": [f"llama-{LLAMA_RELEASE}-bin-win-cuda-13.4-x64.zip", "cudart-llama-bin-win-cuda-13.4-x64.zip"],
}
MLX_BF16 = ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48")
PLTOBING = ("pltobing/Qwen3-TTS-Streaming-ONNX", "4e24bde29755c202827b109cd9e80e34ce5f097d")
WHISPER = ("mlx-community/whisper-large-v3-turbo", "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb")


def qwentts(talker: str) -> tuple[str, str]:
    """(talker path, codec path) for e.g. talker='1.7b-base-Q8_0'."""
    repo, revision = QWENTTS_GGUF
    return (
        hf_hub_download(repo, f"qwen-talker-{talker}.gguf", revision=revision),
        hf_hub_download(repo, QWENTTS_CODEC, revision=revision),
    )


def llama_gguf(quant: str = "Q8_0") -> tuple[str, str]:
    repo, revision = LLAMA_GGUF
    return (
        hf_hub_download(repo, f"Qwen3-TTS-12Hz-1.7B-Base-{quant}.gguf", revision=revision),
        hf_hub_download(repo, "mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf", revision=revision),
    )


def llama_bin() -> Path:
    """llama.cpp's release binaries for this OS, unpacked into bin/llama-<release>/."""
    target = LAB_DIR / "bin" / f"llama-{LLAMA_RELEASE}"
    if not target.exists():
        for asset in LLAMA_ASSETS[platform.system()]:
            url = f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA_RELEASE}/{asset}"
            data = urllib.request.urlopen(url).read()
            if asset.endswith(".zip"):
                zipfile.ZipFile(io.BytesIO(data)).extractall(target)
            else:
                tarfile.open(fileobj=io.BytesIO(data)).extractall(target, filter="data")
    exe = "llama-tts.exe" if sys.platform == "win32" else "llama-tts"
    return next(target.rglob(exe))


def pltobing() -> str:
    return snapshot_download(PLTOBING[0], revision=PLTOBING[1], allow_patterns=["qwen3-tts_onnx/*", "configs/*", "src/**"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--talkers", nargs="*", default=["1.7b-base-BF16", "1.7b-base-Q8_0", "1.7b-base-Q4_K_M", "0.6b-base-Q8_0"])
    args = parser.parse_args()
    for talker in args.talkers:
        print(qwentts(talker))
    print(llama_gguf())
    print(llama_bin())
    if sys.platform == "darwin":
        print(snapshot_download(MLX_BF16[0], revision=MLX_BF16[1]))
        print(snapshot_download(WHISPER[0], revision=WHISPER[1]))
    else:
        print(pltobing())


if __name__ == "__main__":
    main()
