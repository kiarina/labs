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
from mlx_audio.tts.models.qwen3_tts.qwen3_tts import Model as Qwen3TTSModel  # noqa: E402
from mlx_audio.tts.models.qwen3_tts.speech_tokenizer import Qwen3TTSSpeechTokenizerDecoder  # noqa: E402
from mlx_audio.tts.utils import load_model  # noqa: E402

# mlx-audio 0.6.0 decodes voice-clone output without streaming as [reference codes + generated codes] and trims the
# reference part, but its streaming path resets the decoder and decodes the generated codes with no left context, so
# the first chunk differs (README). Priming the streaming decoder with the reference codes makes both paths match.
prime = {"enabled": False, "codes": None, "tokens": 0}
_prepare_icl = Qwen3TTSModel._prepare_icl_generation_inputs
_reset = Qwen3TTSSpeechTokenizerDecoder.reset_streaming_state


def _prepare_icl_and_keep_reference(self, *args, **kwargs):
    result = _prepare_icl(self, *args, **kwargs)
    prime["codes"] = result[3]  # ref_codes [1, 16, ref_time]
    return result


def _reset_and_prime(self):
    _reset(self)
    codes, prime["codes"] = prime["codes"], None
    if prime["enabled"] and codes is not None:
        if prime["tokens"] > 0:
            codes = codes[:, :, -prime["tokens"] :]  # only the end of the reference, as left context
        mx.eval(self.streaming_step(codes))  # output discarded; only the decoder state is kept


Qwen3TTSModel._prepare_icl_generation_inputs = _prepare_icl_and_keep_reference
Qwen3TTSSpeechTokenizerDecoder.reset_streaming_state = _reset_and_prime

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
    prime["enabled"] = stream and bool(request.get("prime_decoder", True)) and bool(request.get("reference_text"))
    prime["tokens"] = int(request.get("prime_tokens", 0))  # 0: the whole reference

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
        "mode": "voice clone"
        + (f" · streaming {interval:g} 秒" if stream else "")
        + ((" · 話し始めの補正 " + (f"末尾 {prime['tokens']} 符号" if prime["tokens"] else "参照の全部")) if prime["enabled"] else ""),
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
