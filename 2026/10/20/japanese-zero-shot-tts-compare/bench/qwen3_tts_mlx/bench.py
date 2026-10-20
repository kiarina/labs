"""Speed and memory of Qwen3-TTS 1.7B Base voice cloning on MLX (mlx-audio), same input as the web UI's first run.

Usage: uv run python bench.py {bf16,8bit,4bit} [--keep-cache]
"""

from __future__ import annotations

import argparse
import os
import subprocess
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from huggingface_hub import snapshot_download
from mlx_audio.tts.utils import load_model

LAB_DIR = Path(__file__).resolve().parents[2]
MODELS = {
    "bf16": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48"),
    "8bit": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", "e7dd0585652209fa0d7783659aad4e8a324de11c"),
    "4bit": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit", "37e955a1deb861c088ae5f3a67043185f3d1a60c"),
}
SAMPLE_ASSET = "tests/assets/mp3/conversation_2speaker_14s_16k.mp3"
SPEAKER1_SEGMENTS = [(0.000, 1.851), (4.737, 7.317), (9.677, 11.834)]  # same as server.py
REFERENCE_TEXT = "もしもし、もう駅に着いた？こっちはまだ電車。あと5分くらいかな。助かる。今日は結構寒いね。"
TEXT = "こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？"


def footprint() -> str:
    output = subprocess.run(["footprint", "-p", str(os.getpid())], capture_output=True, text=True).stdout
    return ", ".join(line.strip() for line in output.splitlines() if "phys_footprint" in line)


def make_reference() -> Path:
    """Sample speaker 1 at 24 kHz mono, as server.py prepares it."""
    output = LAB_DIR / "output/bench-reference-speaker1.wav"
    if not output.exists():
        output.parent.mkdir(parents=True, exist_ok=True)
        decoded = output.with_suffix(".full.wav")
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1", str(LAB_DIR.parents[3] / SAMPLE_ASSET), str(decoded)],
            check=True,
        )
        audio, rate = sf.read(decoded, dtype="float32")
        decoded.unlink()
        pieces = [audio[int(start * rate) : int(end * rate)] for start, end in SPEAKER1_SEGMENTS]
        sf.write(output, np.concatenate(pieces), rate, subtype="PCM_16")
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("quantization", choices=MODELS)
    parser.add_argument("--keep-cache", action="store_true", help="keep MLX's buffer cache (default: limit 0)")
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()

    reference = make_reference()
    if not args.keep_cache:
        mx.set_cache_limit(0)
    repo, revision = MODELS[args.quantization]
    path = snapshot_download(repo, revision=revision)
    started = time.perf_counter()
    model = load_model(path)
    print(f"load {time.perf_counter() - started:.1f}s, active {mx.get_active_memory() / 1e9:.2f} GB, {footprint()}")
    mx.reset_peak_memory()
    for run in range(args.runs):
        mx.random.seed(0)
        started = time.perf_counter()
        results = model.generate(text=TEXT, ref_audio=str(reference), ref_text=REFERENCE_TEXT, lang_code="japanese")
        audio = np.concatenate([np.array(result.audio) for result in results])
        elapsed = time.perf_counter() - started
        print(f"run {run + 1}: generate {elapsed:.2f}s, audio {len(audio) / model.sample_rate:.2f}s")
    print(f"MLX peak {mx.get_peak_memory() / 1e9:.2f} GB, {footprint()}")
    output = LAB_DIR / f"output/mlx-{args.quantization}.wav"
    sf.write(output, audio, model.sample_rate)
    print(f"wrote {output.relative_to(LAB_DIR)}")


if __name__ == "__main__":
    main()
