"""pltobing/Qwen3-TTS-Streaming-ONNX (0.6B Base, fp32) on ONNX Runtime, through the port's own streaming engine.

The engine (`src/inference/qwen3_tts_inferencer_onnx.py`, Apache-2.0, pinned in download.py) is imported from the
downloaded snapshot as published. It clones from the reference's x-vector only (no reference codes or transcript in the
prompt), takes text as streamed deltas, and decodes in 4-frame (320 ms) chunks with the codec decoder's own caches.
On the Mac it runs with `use_cuda=False` (CPU EP); with `cuda=True` (Windows) it runs as published, on CUDA's EP with
CUDA graphs and IOBinding.

`sampling="published"` keeps the port's defaults (temperature 0.75, top-p 0.85, top-k 50, repetition penalty 9.5 over a
75-token window); `sampling="qwen"` uses the checkpoint's generation_config.json (0.9, 1.0, 50, 1.05) with the same window.
"""

from __future__ import annotations

import logging
import sys
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort

from download import pltobing

from .common import SAMPLE_RATE, Synthesis, reference_wav

SAMPLING = {
    "published": {"temperature": 0.75, "top_p": 0.85, "top_k": 50, "repetition_penalty": 9.5},
    "qwen": {"temperature": 0.9, "top_p": 1.0, "top_k": 50, "repetition_penalty": 1.05},
}


class Engine:
    def __init__(self, sampling: str = "published", threads: int = 4, delta_chars: int = 1, cuda: bool = False) -> None:
        self.sampling, self.threads, self.delta_chars, self.cuda = sampling, threads, delta_chars, cuda
        self.name = f"pl-0.6b-fp32-{sampling}-" + ("cuda" if cuda else f"t{threads}")
        self.description = (
            f"pltobing 0.6B Base fp32 (x-vector only, streaming text in {delta_chars}-char deltas), "
            f"{sampling} sampling, ONNX Runtime {ort.__version__} " + ("CUDA EP with CUDA graphs" if cuda else f"CPU EP, {threads} threads")
        )

    def load(self) -> None:
        root = Path(pltobing())
        sys.path.insert(0, str(root))
        from src.inference import Qwen3TTSInferencerONNX  # noqa: PLC0415

        logging.getLogger("src").setLevel(logging.WARNING)  # it logs whole embedding arrays at INFO
        onnx = root / "qwen3-tts_onnx"
        configs = root / "configs"
        self.engine = Qwen3TTSInferencerONNX(
            talker_model_prefill_path=str(onnx / "talker_model_prefill.onnx"),
            talker_model_step_path=str(onnx / "talker_model_step.onnx"),
            talker_local_model_prefill_path=str(onnx / "talker_local_model_prefill.onnx"),
            talker_local_model_step_path=str(onnx / "talker_local_model_step.onnx"),
            talker_local_lm_head_model_path=str(onnx / "talker_local_lm_head.onnx"),
            codec_decoder_model_path=str(onnx / "codec_decoder_model.onnx"),
            codec_decoder_model_dynamic_chunks_path=str(onnx / "codec_decoder_model_dynamic_chunks.onnx"),
            speaker_encoder_model_path=str(onnx / "speaker_encoder_model.onnx"),
            talker_codec_embed_model_path=str(onnx / "talker_codec_embed_model.onnx"),
            text_embed_proj_model_path=str(onnx / "text_embed_proj_model.onnx"),
            preprocessor_config_dir=str(configs),
            model_config_path=str(configs / "config.json"),
            codec_config_path=str(configs / "speech_tokenizer_config.json"),
            audio_ref_path=str(reference_wav()),
            language="japanese",
            use_cuda=self.cuda,
            enable_cuda_graph=self.cuda,
            num_threads=self.threads,
            repetition_window=75,
            **SAMPLING[self.sampling],
        )

    def synthesize(self, text: str, seed: int) -> Synthesis:
        np.random.seed(seed)  # the port samples with np.random
        engine, chunks, arrivals, frames = self.engine, [], [], 0
        started = time.perf_counter()

        def collect(token_frames):
            nonlocal frames
            for frame in token_frames:
                frames += 1
                engine.push_tokens(frame.squeeze(0))
                for wav in engine.audio_chunks():
                    chunks.append(np.asarray(wav, np.float32).reshape(-1))
                    arrivals.append((time.perf_counter() - started, chunks[-1].size / SAMPLE_RATE))

        engine.reset_turn(reset_cache=True, force_reset_codec_cache=True)
        for i in range(0, len(text), self.delta_chars):
            collect(engine.push_text(text[i : i + self.delta_chars]))
        collect(engine.end_text())
        collect(engine.drain())
        final = engine.flush()
        if final is not None and np.size(final):
            chunks.append(np.asarray(final, np.float32).reshape(-1))
            arrivals.append((time.perf_counter() - started, chunks[-1].size / SAMPLE_RATE))
        elapsed = time.perf_counter() - started
        audio = np.concatenate(chunks) if chunks else np.zeros(0, np.float32)
        return Synthesis(audio, elapsed, arrivals, frames=frames)

    def memory(self) -> dict:
        return {}
