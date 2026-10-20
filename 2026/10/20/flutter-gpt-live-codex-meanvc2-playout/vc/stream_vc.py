"""Streaming MeanVC2 on the CPU, using upstream `runtime/run_rt.py` unchanged.

Upstream `VCRunner.process_chunk` is the streaming path (ASR with caches, DiT
with KV cache, Vocos with overlap). Only its constructor is replaced: the target
speaker embedding is made with the same WavLM + ECAPA encoder as the file-mode
lab (`preprocess/models/ecapa_tdnn.py` + `wavlm_large.pt`), because the runtime's
own loader expects a `wavlm_large_cfg.pt` that the published assets do not ship.
"""
from __future__ import annotations

import importlib.util
import sys
import time
import types
from pathlib import Path

import numpy as np
import torch

from meanvc2_runtime import ensure_assets, load_vc_weights  # noqa: F401  (hash-verified assets)

HERE = Path(__file__).resolve().parent
CHUNK = 2560  # 160 ms at 16 kHz, as upstream


def _load_runtime(source_dir: Path):
    runtime = source_dir / "runtime"
    # runtime/src is a package named `src`; register it under a private name.
    package = types.ModuleType("rt_src")
    package.__path__ = [str(runtime / "src")]
    sys.modules["rt_src"] = package
    for name in ("modules", "dit_modules", "dit"):
        spec = importlib.util.spec_from_file_location(f"rt_src.{name}", runtime / "src" / f"{name}.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[f"rt_src.{name}"] = module
        spec.loader.exec_module(module)
    # run_rt imports `from src.dit import DiT` / `from src.speaker import ...`.
    sys.modules.setdefault("src", package)
    sys.modules["src.dit"] = sys.modules["rt_src.dit"]
    speaker = types.ModuleType("src.speaker")
    speaker.init_speaker_model = None
    speaker.extract_embedding = None
    sys.modules["src.speaker"] = speaker
    spec = importlib.util.spec_from_file_location("meanvc2_run_rt", runtime / "run_rt.py")
    run_rt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(run_rt)
    return run_rt


def _vc_step(self, cond: torch.Tensor) -> torch.Tensor:
    """Upstream `VCRunner._vc_step` with the ODE step count taken from
    `self.ode_steps` instead of the fixed 2 (same mean-flow update otherwise)."""
    n = self.ode_steps
    dt = 1.0 / n
    with torch.no_grad():
        x = torch.randn(1, cond.shape[1], 80, device=cond.device, dtype=cond.dtype)
        if self.noise_cache is not None:
            x[:, :self.block_size, :] = self.noise_cache
        self.noise_cache = x[:, -self.block_size:, :].clone()
        if self.vc_offset >= 4000:
            self.vc_offset = 0
            self.vc_kv_cache = None
        pre_kv_cache = self.vc_kv_cache
        for i in range(n):
            t_val = 1.0 - i * dt
            r_val = max(0.0, t_val - dt)
            u, tmp_kv_cache = self.vc(
                x, torch.full((1,), t_val), torch.full((1,), r_val), cache=None, cond=cond,
                spks=self.vc_spk_emb, offset=self.vc_offset, is_inference=True,
                kv_cache=pre_kv_cache, gtm_kv=self.vc_gtm_kv)
            x = x - dt * u
            if i == n - 1:
                self.vc_kv_cache = tmp_kv_cache
        self.vc_offset += self.chunk_size
        return x[:, :self.chunk_size, :].transpose(1, 2)


class StreamingVC:
    def __init__(self, threads: int = 1, model: str = "120ms", steps: int = 2) -> None:
        self.source_dir, s3prl_dir = ensure_assets(HERE)
        torch.set_num_threads(threads)
        for path in (s3prl_dir, self.source_dir):
            if str(path) not in sys.path:
                sys.path.insert(0, str(path))
        run_rt = _load_runtime(self.source_dir)
        from preprocess.models.ecapa_tdnn import ECAPA_TDNN_SMALL

        started = time.perf_counter()
        speaker = ECAPA_TDNN_SMALL(feat_dim=1024, feat_type="wavlm_large")
        state = torch.load(self.source_dir / "preprocess/ckpts/wavlm_large_finetune.pth", map_location="cpu")
        speaker.load_state_dict(state["model"], strict=False)
        self.speaker = speaker.eval()
        paths = run_rt.MODEL_PATHS[model]
        cls = type("StepsRunner", (run_rt.VCRunner,), {"_vc_step": _vc_step})
        runner = cls.__new__(cls)
        runner.ode_steps = steps
        runner.device = "cpu"
        runner._asr_ckpt = paths["asr_ckpt"]
        runner._bn_window = paths["bn_window"]
        runner._bn_stride = paths["bn_stride"]
        runner._required_cache_size = paths["required_cache_size"]
        runner._asr_offset_init = paths["asr_offset_init"]
        runner._asr_offset_step = paths["asr_offset_step"]
        runner.asr = torch.jit.load(paths["asr_ckpt"]).eval()
        runner.vc = run_rt._load_vc_model(paths["config"], paths["ckpt"], "cpu")
        runner.vocoder = torch.jit.load(run_rt.VOCODER_PATH)
        runner.chunk_size = 12 if model == "120ms" else 4
        runner.block_size = 4
        runner.CHUNK = CHUNK
        runner.vocoder_overlap = 2
        runner.upsample_factor = 160
        runner.vocoder_wav_overlap = 160
        runner.vocoder_wav_pad = (runner.vocoder_overlap - 1) * runner.upsample_factor - runner.vocoder_wav_overlap
        runner.down_linspace = torch.linspace(1, 0, steps=runner.vocoder_wav_overlap)
        runner.up_linspace = torch.linspace(0, 1, steps=runner.vocoder_wav_overlap)
        self.runner = runner
        self.model = model
        self.steps = steps
        self.load_seconds = time.perf_counter() - started

    @torch.inference_mode()
    def set_target(self, audio16k: np.ndarray) -> float:
        started = time.perf_counter()
        emb = self.speaker(torch.from_numpy(audio16k.astype(np.float32)).unsqueeze(0))
        self.runner.vc_spk_emb = emb
        self.runner.vc_gtm_kv = self.runner.vc.gtm(emb)
        self.reset()
        return time.perf_counter() - started

    def reset(self) -> None:
        self.runner._init_cache()

    def process(self, samples16k: np.ndarray) -> np.ndarray:
        """Feed any number of 16 kHz float samples; returns converted samples so far."""
        out = self.runner.process_chunk(samples16k.astype(np.float32))
        return np.zeros(0, np.float32) if out is None else out.astype(np.float32)
