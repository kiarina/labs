"""Fetch the pinned ONNX ports, the upstream configs/tokenizers, and the MLX baseline into the Hugging Face cache.

Usage: uv run download.py [--precisions fp32 fp16 int4]
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from huggingface_hub import snapshot_download

LAB_DIR = Path(__file__).resolve().parent

# The ports under test, pinned to the commits this lab measured.
ONNX_COMMUNITY = ("onnx-community/Qwen3-TTS-12Hz-1.7B-Base", "16ec6f3335d919e0e007d825a6f47fdd2cd77594")
PLTOBING = ("pltobing/Qwen3-TTS-Streaming-ONNX", "4e24bde29755c202827b109cd9e80e34ce5f097d")
# Config and tokenizer for the onnx-community port (it ships neither), and the MLX baseline.
QWEN_17B = ("Qwen/Qwen3-TTS-12Hz-1.7B-Base", "fd4b254389122332181a7c3db7f27e918eec64e3")
MLX_BF16 = ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48")
WHISPER = ("mlx-community/whisper-large-v3-turbo", "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb")


def onnx_community(precision: str, device: str = "cpu") -> str:
    """The port's files for one device and precision (`cpu_*` or `cuda_*`), hard-linked into models/ (no extra disk).

    ONNX Runtime 1.31 refuses external data (`talker_cache.onnx.data`) when the model is reached through the Hugging Face
    cache's symlinks ("External data path escapes model directory"), so the session reads plain files here instead.
    talker.onnx is the no-cache talker; generation here uses talker_cache.onnx (prefill = empty past), so it is skipped.
    """
    snapshot = Path(
        snapshot_download(
            ONNX_COMMUNITY[0],
            revision=ONNX_COMMUNITY[1],
            allow_patterns=[f"{device}_{precision}/*", "inference.py", "STATUS.md"],
            ignore_patterns=[f"{device}_{precision}/talker.onnx", f"{device}_{precision}/talker.onnx.data"],
        )
    )
    target = LAB_DIR / "models/onnx-community"
    for source in (snapshot / f"{device}_{precision}").iterdir():
        link = target / f"{device}_{precision}" / source.name
        if not link.exists():
            link.parent.mkdir(parents=True, exist_ok=True)
            os.link(source.resolve(), link)
    return str(target)


def pltobing() -> str:
    return snapshot_download(
        PLTOBING[0], revision=PLTOBING[1], allow_patterns=["qwen3-tts_onnx/*", "configs/*", "src/**", "*.py", "README.md"]
    )


def qwen_17b() -> str:
    return snapshot_download(QWEN_17B[0], revision=QWEN_17B[1], allow_patterns=["*.json", "*.txt"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--precisions", nargs="*", default=["fp32", "fp16", "int4"])
    args = parser.parse_args()
    for precision in args.precisions:
        print(onnx_community(precision))
    print(pltobing())
    print(qwen_17b())
    print(snapshot_download(MLX_BF16[0], revision=MLX_BF16[1]))
    print(snapshot_download(WHISPER[0], revision=WHISPER[1]))


if __name__ == "__main__":
    main()
