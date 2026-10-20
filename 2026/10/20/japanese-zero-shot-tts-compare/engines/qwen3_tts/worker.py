"""Qwen3-TTS voice clone worker: one JSON request per line on stdin, one JSON reply per line on $WORKER_REPLY_FD."""

from __future__ import annotations

import json
import os
import sys
import time
import traceback
from pathlib import Path

LAB_DIR = Path(__file__).resolve().parents[2]
MODELS = {
    # name -> (Hugging Face repo, revision)
    "1.7B": ("Qwen/Qwen3-TTS-12Hz-1.7B-Base", "fd4b254389122332181a7c3db7f27e918eec64e3"),
    "0.6B": ("Qwen/Qwen3-TTS-12Hz-0.6B-Base", "5d83992436eae1d760afd27aff78a71d676296fc"),
}
LANGUAGES = {"ja": "Japanese", "en": "English", "zh": "Chinese", "ko": "Korean"}
# MPS with bfloat16 was the fastest of MPS bf16 / MPS fp32 / CPU fp32 on M1 Max (README).
DEVICE = os.environ.get("QWEN3_TTS_DEVICE", "mps")
DTYPE = os.environ.get("QWEN3_TTS_DTYPE", "bfloat16")

# Libraries print to stdout; keep replies on a private descriptor.
replies = os.fdopen(int(os.environ["WORKER_REPLY_FD"]), "w", buffering=1)
sys.stdout = sys.stderr

import soundfile as sf  # noqa: E402
import torch  # noqa: E402
from huggingface_hub import snapshot_download  # noqa: E402
from qwen_tts import Qwen3TTSModel  # noqa: E402

models: dict[str, Qwen3TTSModel] = {}
prompts: dict[tuple, object] = {}


def model(name: str) -> Qwen3TTSModel:
    if name not in models:
        repo, revision = MODELS[name]
        path = snapshot_download(repo, revision=revision, local_dir=LAB_DIR / "models" / repo.split("/")[-1])
        models[name] = Qwen3TTSModel.from_pretrained(
            path, device_map=DEVICE, dtype=getattr(torch, DTYPE), attn_implementation="sdpa"
        )
    return models[name]


def synthesize(request: dict) -> dict:
    name = request.get("model", "1.7B")
    timings = {}
    started = time.perf_counter()
    tts = model(name)
    timings["load"] = time.perf_counter() - started

    reference_text = request.get("reference_text") or ""
    key = (name, request["reference_wav"], reference_text)
    if key not in prompts:
        started = time.perf_counter()
        prompts[key] = tts.create_voice_clone_prompt(
            ref_audio=request["reference_wav"],
            ref_text=reference_text or None,
            # Without a transcript only the speaker embedding is used (upstream: lower quality).
            x_vector_only_mode=not reference_text,
        )
        timings["prompt"] = time.perf_counter() - started

    torch.manual_seed(int(request.get("seed", 0)))
    started = time.perf_counter()
    wavs, sample_rate = tts.generate_voice_clone(
        text=request["text"],
        language=LANGUAGES.get(request.get("language", "ja"), "Auto"),
        voice_clone_prompt=prompts[key],
    )
    timings["generate"] = time.perf_counter() - started
    sf.write(request["output_wav"], wavs[0], sample_rate)
    return {
        "engine": "qwen3_tts",
        "model": name,
        "device": f"{DEVICE} {DTYPE}",
        "input_text": request["text"],
        "mode": "voice clone" if reference_text else "voice clone (x-vector only)",
        "sample_rate": sample_rate,
        "seconds": len(wavs[0]) / sample_rate,
        "timings": timings,
    }


def main() -> None:
    model("1.7B")
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
