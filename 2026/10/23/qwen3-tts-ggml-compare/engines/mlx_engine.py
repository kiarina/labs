"""Baseline: Qwen3-TTS 1.7B Base bf16 on MLX (mlx-audio 0.6.1), configured as kiapi serves it.

Two corrections from japanese-zero-shot-tts-compare are applied (that lab's README explains both):
- generation matches qwen-tts 0.1.1: the prompt layout of `non_streaming_mode=False` (text overlaid on the reference codes,
  leftover text fed one token per step) and a 1.05 repetition penalty over all generated tokens;
- streaming primes the codec decoder with the reference codes, so the first chunk has its left context.
"""

from __future__ import annotations

import time

import mlx.core as mx
import numpy as np
from huggingface_hub import snapshot_download
from mlx_audio.tts.models.qwen3_tts.qwen3_tts import Model as Qwen3TTSModel
from mlx_audio.tts.models.qwen3_tts.speech_tokenizer import Qwen3TTSSpeechTokenizerDecoder
from mlx_audio.tts.utils import load_model

from .common import REFERENCE_TEXT, SAMPLE_RATE, Synthesis, reference_wav

REPO, REVISION = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48"

_prepare_icl = Qwen3TTSModel._prepare_icl_generation_inputs
_generate_icl = Qwen3TTSModel._generate_icl
_sample_token = Qwen3TTSModel._sample_token
_reset = Qwen3TTSSpeechTokenizerDecoder.reset_streaming_state
_state = {"codes": None}


def _qwen_tts_layout(self, input_embeds, text, ref_text, ref_codes):
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
    prefix = input_embeds[:, : input_embeds.shape[1] - text_lens - codec_lens]
    if text_lens > codec_lens:
        icl, trailing = text_embed[:, :codec_lens] + codec_embed, text_embed[:, codec_lens:]
    else:
        pad = mx.broadcast_to(tts_pad, (1, codec_lens - text_lens, tts_pad.shape[-1]))
        icl, trailing = mx.concatenate([text_embed, pad], axis=1) + codec_embed, tts_pad
    return mx.concatenate([prefix, icl], axis=1), trailing


def _prepare(self, text, ref_audio, ref_text, language="auto"):
    result = _prepare_icl(self, text, ref_audio, ref_text, language)
    _state["codes"] = result[3]
    input_embeds, trailing = _qwen_tts_layout(self, result[0], text, ref_text, result[3])
    return input_embeds, trailing, result[2], result[3]


def _generate(self, *args, **kwargs):
    kwargs["repetition_penalty"] = 1.05
    return _generate_icl(self, *args, **kwargs)


def _sample(self, logits, *args, **kwargs):
    if kwargs.get("generated_tokens"):
        kwargs["repetition_context_size"] = len(kwargs["generated_tokens"])
    return _sample_token(self, logits, *args, **kwargs)


def _reset_and_prime(self):
    _reset(self)
    codes, _state["codes"] = _state["codes"], None
    if codes is not None:
        mx.eval(self.streaming_step(codes))


Qwen3TTSModel._prepare_icl_generation_inputs = _prepare
Qwen3TTSModel._generate_icl = _generate
Qwen3TTSModel._sample_token = _sample
Qwen3TTSSpeechTokenizerDecoder.reset_streaming_state = _reset_and_prime


class Engine:
    name = "mlx-1.7b-bf16"
    description = "MLX bf16 1.7B Base (mlx-audio 0.6.1, qwen-tts layout, streaming 0.5 s)"

    def __init__(self, streaming_interval: float = 0.5) -> None:
        self.interval = streaming_interval

    def load(self) -> None:
        mx.set_cache_limit(1 << 30)
        self.model = load_model(snapshot_download(REPO, revision=REVISION))
        self.reference = str(reference_wav())

    def synthesize(self, text: str, seed: int) -> Synthesis:
        mx.random.seed(seed)
        chunks, arrivals = [], []
        started = time.perf_counter()
        for result in self.model.generate(
            text=text,
            lang_code="japanese",
            ref_audio=self.reference,
            ref_text=REFERENCE_TEXT,
            stream=True,
            streaming_interval=self.interval,
        ):
            audio = np.array(result.audio, dtype=np.float32)
            arrivals.append((time.perf_counter() - started, len(audio) / SAMPLE_RATE))
            chunks.append(audio)
        elapsed = time.perf_counter() - started
        audio = np.concatenate(chunks)
        return Synthesis(audio, elapsed, arrivals, frames=round(len(audio) / 1920))

    def memory(self) -> dict:
        return {"mlx_peak_gb": mx.get_peak_memory() / 1e9}
