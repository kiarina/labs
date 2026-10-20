"""Qwen3-TTS on MLX (mlx-audio) worker: one JSON request per line on stdin, one JSON reply per line on $WORKER_REPLY_FD."""

from __future__ import annotations

import json
import os
import sys
import time
import traceback

MODELS = {
    # quantization -> (Hugging Face repo, revision)
    "bf16": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48"),
    "8bit": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", "e7dd0585652209fa0d7783659aad4e8a324de11c"),
    "4bit": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit", "37e955a1deb861c088ae5f3a67043185f3d1a60c"),
}
LANGUAGES = {"ja": "japanese", "en": "english", "zh": "chinese", "ko": "korean"}

replies = os.fdopen(int(os.environ["WORKER_REPLY_FD"]), "w", buffering=1)
sys.stdout = sys.stderr

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
from huggingface_hub import snapshot_download  # noqa: E402
from mlx_audio.tts.utils import load_model  # noqa: E402

mx.set_cache_limit(1 << 30)  # keep the buffer cache from holding several GB between requests
models: dict[str, object] = {}


def model(quantization: str):
    if quantization not in models:
        repo, revision = MODELS[quantization]
        models[quantization] = load_model(snapshot_download(repo, revision=revision))
    return models[quantization]


def playback_stalls(arrivals: list[tuple[float, float]]) -> float:
    """Seconds of silence if playback starts at the first chunk and plays chunks back to back."""
    play_end, stalls = arrivals[0][0], 0.0
    for arrived, duration in arrivals:
        if arrived > play_end:
            stalls += arrived - play_end
            play_end = arrived
        play_end += duration
    return stalls


def synthesize(request: dict) -> dict:
    quantization = request.get("quantization", "8bit")
    started = time.perf_counter()
    tts = model(quantization)
    load = time.perf_counter() - started

    stream = bool(request.get("stream", False))
    interval = float(request.get("streaming_interval", 0.5))
    kwargs = {
        "text": request["text"],
        "lang_code": LANGUAGES.get(request.get("language", "ja"), "auto"),
        "ref_audio": request["reference_wav"],
    }
    if request.get("reference_text"):
        kwargs["ref_text"] = request["reference_text"]
    if stream:
        kwargs.update(stream=True, streaming_interval=interval)

    mx.random.seed(int(request.get("seed", 0)))
    mx.reset_peak_memory()
    chunks, arrivals = [], []
    started = time.perf_counter()
    for result in tts.generate(**kwargs):
        audio = np.array(result.audio)
        arrivals.append((time.perf_counter() - started, len(audio) / tts.sample_rate))
        chunks.append(audio)
    generate = time.perf_counter() - started
    audio = np.concatenate(chunks)
    sf.write(request["output_wav"], audio, tts.sample_rate)
    reply = {
        "engine": "qwen3_tts_mlx",
        "model": f"1.7B {quantization}",
        "device": "MLX",
        "input_text": request["text"],
        "mode": "voice clone" + (f" · streaming {interval:g} 秒" if stream else ""),
        "sample_rate": tts.sample_rate,
        "seconds": len(audio) / tts.sample_rate,
        "timings": {"load": load, "generate": generate},
        "first_audio_seconds": arrivals[0][0],
        "chunks": len(arrivals),
        "peak_memory_gb": mx.get_peak_memory() / 1e9,
    }
    if stream:
        reply["stall_seconds"] = playback_stalls(arrivals)
        reply["arrivals"] = [[round(at, 3), round(duration, 3)] for at, duration in arrivals]
    return reply


def main() -> None:
    for quantization in MODELS:
        model(quantization)
    replies.write(json.dumps({"ready": True}) + "\n")
    for line in sys.stdin:
        request = json.loads(line)
        try:
            reply = {"id": request.get("id"), "ok": True, **synthesize(request)}
        except Exception as error:
            traceback.print_exc()
            reply = {"id": request.get("id"), "ok": False, "error": f"{type(error).__name__}: {error}"}
        replies.write(json.dumps(reply, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
