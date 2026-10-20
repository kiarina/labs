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
    # The bf16 weights cast to float32 (the original PyTorch weights are the same bf16 values, so nothing is lost);
    # computation then runs in float32, as in the parity check (bench/qwen3_tts_parity/mlx_compare.py).
    "fp32": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48"),
}
LANGUAGES = {"ja": "japanese", "en": "english", "zh": "chinese", "ko": "korean"}

replies = os.fdopen(int(os.environ["WORKER_REPLY_FD"]), "w", buffering=1)
sys.stdout = sys.stderr

import mlx.core as mx  # noqa: E402
from mlx.utils import tree_map  # noqa: E402
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


# mlx-audio 0.6.0 voice cloning also differs from qwen-tts 0.1.1's `generate_voice_clone` defaults in two ways, while each
# module matches PyTorch in float32 (README, "MLX vs PyTorch, stage by stage"):
# - prompt layout: qwen-tts defaults to non_streaming_mode=False, which overlays the text (reference + target + eos) on the
#   reference codes, position by position, and feeds any text left over one token per generated step; mlx-audio always
#   builds the non-streaming layout (all text over codec pad, then the reference codes over text pad).
# - repetition penalty: mlx-audio raises it to at least 1.5 for voice cloning and applies it to the last 64 tokens;
#   qwen-tts uses the checkpoint's 1.05 over all generated tokens (transformers' RepetitionPenaltyLogitsProcessor).
# `match_pytorch` switches both to the qwen-tts behavior (`layout` and `penalty` separately for bench/qwen3_tts_parity).
match = {"layout": False, "penalty": False, "repetition_penalty": 1.05}
_generate_icl = Qwen3TTSModel._generate_icl
_sample_token = Qwen3TTSModel._sample_token


def _streaming_text_layout(self, input_embeds, text, ref_text, ref_codes):
    """Rebuild the voice-clone prompt in qwen-tts's non_streaming_mode=False layout (generate_icl_prompt)."""
    talker, config = self.talker, self.config.talker_config
    ref_ids = mx.array(self.tokenizer.encode(f"<|im_start|>assistant\n{ref_text}<|im_end|>\n"))[None, 3:-2]
    text_ids = mx.array(self.tokenizer.encode(f"<|im_start|>assistant\n{text}<|im_end|>\n<|im_start|>assistant\n"))[None, 3:-5]
    special = talker.text_projection(
        talker.get_text_embeddings()(mx.array([[self.config.tts_eos_token_id, self.config.tts_pad_token_id]]))
    )
    tts_eos, tts_pad = special[:, 0:1], special[:, 1:2]
    text_embed = talker.text_projection(talker.get_text_embeddings()(mx.concatenate([ref_ids, text_ids], axis=1)))
    text_embed = mx.concatenate([text_embed, tts_eos], axis=1)
    codec_embed = talker.get_input_embeddings()(ref_codes[:, 0, :])
    for i in range(config.num_code_groups - 1):
        codec_embed = codec_embed + talker.code_predictor.codec_embedding[i](ref_codes[:, i + 1, :])
    codec_embed = mx.concatenate([talker.get_input_embeddings()(mx.array([[config.codec_bos_id]])), codec_embed], axis=1)
    text_lens, codec_lens = text_embed.shape[1], codec_embed.shape[1]
    prefix = input_embeds[:, : input_embeds.shape[1] - text_lens - codec_lens]  # role + codec prefix, same in both layouts
    if text_lens > codec_lens:
        icl, trailing = text_embed[:, :codec_lens] + codec_embed, text_embed[:, codec_lens:]
    else:
        pad = mx.broadcast_to(tts_pad, (1, codec_lens - text_lens, tts_pad.shape[-1]))
        icl, trailing = mx.concatenate([text_embed, pad], axis=1) + codec_embed, tts_pad
    return mx.concatenate([prefix, icl], axis=1), trailing


def _prepare_icl_and_keep_reference(self, text, ref_audio, ref_text, language="auto"):
    result = _prepare_icl(self, text, ref_audio, ref_text, language)
    prime["codes"] = result[3]  # ref_codes [1, 16, ref_time]
    if match["layout"]:
        input_embeds, trailing = _streaming_text_layout(self, result[0], text, ref_text, result[3])
        result = (input_embeds, trailing, result[2], result[3])
    return result


def _generate_icl_matching(self, *args, **kwargs):
    if match["penalty"]:
        kwargs["repetition_penalty"] = match["repetition_penalty"]  # instead of max(penalty, 1.5)
    return _generate_icl(self, *args, **kwargs)


def _sample_token_matching(self, logits, *args, **kwargs):
    if match["penalty"] and kwargs.get("generated_tokens"):
        kwargs["repetition_context_size"] = len(kwargs["generated_tokens"])  # all generated tokens, not the last 64
    return _sample_token(self, logits, *args, **kwargs)


def _reset_and_prime(self):
    _reset(self)
    codes, prime["codes"] = prime["codes"], None
    if prime["enabled"] and codes is not None:
        if prime["tokens"] > 0:
            codes = codes[:, :, -prime["tokens"] :]  # only the end of the reference, as left context
        mx.eval(self.streaming_step(codes))  # output discarded; only the decoder state is kept


Qwen3TTSModel._prepare_icl_generation_inputs = _prepare_icl_and_keep_reference
Qwen3TTSSpeechTokenizerDecoder.reset_streaming_state = _reset_and_prime
Qwen3TTSModel._generate_icl = _generate_icl_matching
Qwen3TTSModel._sample_token = _sample_token_matching

mx.set_cache_limit(1 << 30)  # keep the buffer cache from holding several GB between requests
models: dict[str, object] = {}


def model(quantization: str):
    if quantization not in models:
        repo, revision = MODELS[quantization]
        path = snapshot_download(repo, revision=revision)
        if quantization == "fp32":
            # load_model compiles the speech decoder, and a compiled module cannot be updated. Load it uncompiled, cast,
            # then compile it as load_model does (as in bench/qwen3_tts_parity/mlx_compare.py).
            compile_ = mx.compile
            mx.compile = lambda fn, *args, **kwargs: fn
            try:
                loaded = load_model(path)
            finally:
                mx.compile = compile_
            loaded.update(tree_map(lambda p: p.astype(mx.float32) if mx.issubdtype(p.dtype, mx.floating) else p, loaded.parameters()))
            mx.eval(loaded.parameters())
            loaded.speech_tokenizer.decoder = mx.compile(loaded.speech_tokenizer.decoder)
        else:
            loaded = load_model(path)
        models[quantization] = loaded
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
    match["layout"] = match["penalty"] = bool(request.get("match_pytorch", True)) and bool(request.get("reference_text"))

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
        + (" · PyTorch と同じ設定" if match["layout"] else " · mlx-audio の既定")
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
