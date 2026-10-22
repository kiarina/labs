"""Fetch the pinned qwentts.cpp GGUFs (talker 1.7B Base BF16 and the 12 Hz codec F32) and Whisper (Mac, for the evaluation)."""

from __future__ import annotations

import sys
from pathlib import Path

from huggingface_hub import hf_hub_download, snapshot_download

LAB_DIR = Path(__file__).resolve().parent
QWENTTS_GGUF = ("Serveurperso/Qwen3-TTS-GGUF", "b7ee2e8c7459c3bea99da23e3d178125a7d1713c")
TALKER = "qwen-talker-1.7b-base-BF16.gguf"
CODEC = "qwen-tokenizer-12hz-F32.gguf"
WHISPER = ("mlx-community/whisper-large-v3-turbo", "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb")


def qwentts() -> tuple[str, str]:
    repo, revision = QWENTTS_GGUF
    return hf_hub_download(repo, TALKER, revision=revision), hf_hub_download(repo, CODEC, revision=revision)


if __name__ == "__main__":
    print(qwentts())
    if sys.platform == "darwin":
        print(snapshot_download(WHISPER[0], revision=WHISPER[1]))
