"""Streaming MeanVC2 on ONNX Runtime: upstream `VCRunner.process_chunk` with
every model call replaced by one of the exported graphs.

The bookkeeping (caches, sliding ASR window, BN interpolation, ODE loop,
vocoder cross-fade) is a line-by-line port of upstream `runtime/run_rt.py`
in numpy, so that the Dart port can follow the same code. `record=True` keeps
the per-stage outputs (BN, mel, waveform) for the comparison with upstream.
"""
from __future__ import annotations

import time
from pathlib import Path

import numpy as np
import onnxruntime as ort

CHUNK = 2560          # 160 ms at 16 kHz
BN_WINDOW = 19        # 120ms model (Fast-U2++ 160 ms)
BN_STRIDE = 16
REQUIRED_CACHE = 8
ASR_OFFSET_INIT = 8
ASR_OFFSET_STEP = 4
CHUNK_SIZE = 12       # DiT frames per step (120 ms)
BLOCK_SIZE = 4        # look-ahead frames (40 ms)
VOCODER_OVERLAP = 2
WAV_OVERLAP = 160
WAV_PAD = (VOCODER_OVERLAP - 1) * 160 - WAV_OVERLAP  # 0
DOWN = np.linspace(1, 0, WAV_OVERLAP, dtype=np.float32)
UP = np.linspace(0, 1, WAV_OVERLAP, dtype=np.float32)


# Which graphs are int8 in each variant (export_onnx.py --int8 writes *.int8.onnx).
Q = ".int8"
VARIANTS = {
    "fp32": "",
    "int8": Q,                                   # ASR, DiT and Vocos int8
    "int8-asr": {"asr": Q},
    "int8-dit": {"dit": Q},
    "int8-vocos": {"vocos": Q},
    "int8-asr-dit": {"asr": Q, "dit": Q},        # Vocos stays fp32
}


def interp_linear_align_corners(x: np.ndarray, size: int) -> np.ndarray:
    """F.interpolate(mode='linear', align_corners=True) along axis 0 of [N, C]."""
    n = x.shape[0]
    if n == 1:
        return np.repeat(x, size, axis=0)
    pos = np.arange(size, dtype=np.float32) * np.float32((n - 1) / (size - 1))
    lo = np.minimum(np.floor(pos).astype(np.int64), n - 2)
    w = (pos - lo.astype(np.float32))[:, None]
    return (x[lo] * (1 - w) + x[lo + 1] * w).astype(np.float32)


class OnnxStreamingVC:
    def __init__(self, model_dir: Path, suffix: str | dict = "", threads: int = 1, steps: int = 2,
                 providers=("CPUExecutionProvider",)) -> None:
        so = ort.SessionOptions()
        so.intra_op_num_threads = threads
        so.inter_op_num_threads = 1
        so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        started = time.perf_counter()
        names = ("fbank", "asr", "gtm", "dit", "vocos")
        suffixes = suffix if isinstance(suffix, dict) else {n: suffix for n in names}
        self.s = {n: ort.InferenceSession(str(model_dir / f"{n}{suffixes.get(n, '')}.onnx"), so, providers=list(providers))
                  for n in names}
        self.load_seconds = time.perf_counter() - started
        self.steps = steps
        self.noise_fn = None
        self.rng = np.random.default_rng(0)
        self.record = False
        self.spk = None
        self.reset()

    def set_target(self, spk: np.ndarray) -> None:
        self.spk = spk.reshape(1, 256).astype(np.float32)
        self.k_mem, self.v_mem = self.s["gtm"].run(None, {"spks": self.spk})
        self.reset()

    def reset(self) -> None:
        self.samples_cache = np.zeros(0, np.float32)
        self.frame_cache = None
        self.encoder_output_cache = None
        self.asr_offset = ASR_OFFSET_INIT
        self.att_cache = np.zeros((6, 4, REQUIRED_CACHE, 128), np.float32)
        self.cnn_cache = np.zeros((6, 1, 256, 8), np.float32)
        self.kv = [np.zeros((1, 2, 0, 64), np.float32) for _ in range(8)]
        self.vc_offset = 0
        self.noise_cache = None
        self.vocoder_cache = None
        self.last_wav = None
        self.bn_buffer = None
        self.trace = {"fbank": [], "bn": [], "mel": [], "wav": []}
        self.timing = {"fbank": 0.0, "asr": 0.0, "dit": 0.0, "vocos": 0.0}

    # -- ASR -----------------------------------------------------------------
    def _encode_chunk(self, samples: np.ndarray):
        padded = np.concatenate((self.samples_cache, samples)) if self.samples_cache.size else samples
        if len(padded) < 400:
            self.samples_cache = padded
            return None
        n = 1 + (len(padded) - 400) // 160
        idx = np.arange(400)[None, :] + 160 * np.arange(n)[:, None]
        frames = (padded[idx] * np.float32(1 << 15)).astype(np.float32)
        t0 = time.perf_counter()
        fb = self.s["fbank"].run(None, {"frames": frames})[0]
        self.timing["fbank"] += time.perf_counter() - t0
        if self.record:
            self.trace["fbank"].append(fb)
        self.samples_cache = padded[160 * n:]
        if self.frame_cache is not None:
            fb = np.concatenate([self.frame_cache, fb], axis=0)
        if self.asr_offset >= 4000:
            self.asr_offset = max(REQUIRED_CACHE, self.asr_offset - 4000)
        bns = []
        i = 0
        t0 = time.perf_counter()
        while i + BN_WINDOW <= fb.shape[0]:
            out, self.att_cache, self.cnn_cache = self.s["asr"].run(None, {
                "xs": fb[None, i:i + BN_WINDOW], "offset": np.array(self.asr_offset, np.int64),
                "required_cache_size": np.array(REQUIRED_CACHE, np.int64),
                "att_cache": self.att_cache, "cnn_cache": self.cnn_cache})
            bns.append(out[0])
            self.asr_offset += ASR_OFFSET_STEP
            i += BN_STRIDE
        self.timing["asr"] += time.perf_counter() - t0
        self.frame_cache = fb[i:]
        if not bns:
            return None
        bn = np.concatenate(bns, axis=0)
        if self.encoder_output_cache is not None:
            bn = np.concatenate([self.encoder_output_cache, bn], axis=0)
        self.encoder_output_cache = bn[-1:]
        if bn.shape[0] < 2:
            return None
        return interp_linear_align_corners(bn, 17)[1:]

    # -- DiT -----------------------------------------------------------------
    def _noise(self, n: int) -> np.ndarray:
        if self.noise_fn is not None:
            return self.noise_fn(n)
        return self.rng.standard_normal((1, n, 80), dtype=np.float32)

    def _vc_step(self, cond: np.ndarray) -> np.ndarray:
        n = self.steps
        dt = 1.0 / n
        x = self._noise(cond.shape[0]).copy()
        if self.noise_cache is not None:
            x[:, :BLOCK_SIZE, :] = self.noise_cache
        self.noise_cache = x[:, -BLOCK_SIZE:, :].copy()
        if self.vc_offset >= 4000:
            self.vc_offset = 0
            self.kv = [np.zeros((1, 2, 0, 64), np.float32) for _ in range(8)]
        feed = {"cond": cond[None], "spks": self.spk, "k_mem": self.k_mem, "v_mem": self.v_mem,
                "offset": np.array(self.vc_offset, np.int64)}
        for j in range(4):
            feed[f"k_cache{j}"], feed[f"v_cache{j}"] = self.kv[2 * j], self.kv[2 * j + 1]
        t0 = time.perf_counter()
        for i in range(n):
            t_val = 1.0 - i * dt
            r_val = max(0.0, t_val - dt)
            feed["x"] = x
            feed["t"] = np.array([t_val], np.float32)
            feed["r"] = np.array([r_val], np.float32)
            outs = self.s["dit"].run(None, feed)
            # same float32 arithmetic as `x = x - dt * u` in torch
            x = (x - np.float32(dt) * outs[0]).astype(np.float32)
            if i == n - 1:
                self.kv = outs[1:]
        self.timing["dit"] += time.perf_counter() - t0
        self.vc_offset += CHUNK_SIZE
        mel = np.ascontiguousarray(x[:, :CHUNK_SIZE, :].transpose(0, 2, 1))
        if self.record:
            self.trace["mel"].append(mel)
        return mel

    # -- vocoder -------------------------------------------------------------
    def _decode_mel(self, mel: np.ndarray) -> np.ndarray:
        if self.vocoder_cache is not None:
            mel = np.concatenate([self.vocoder_cache, mel], axis=-1)
        self.vocoder_cache = mel[:, :, -VOCODER_OVERLAP:]
        mel = ((mel + 1) / 2).astype(np.float32)
        t0 = time.perf_counter()
        wav = self.s["vocos"].run(None, {"mel": mel})[0].reshape(-1)
        self.timing["vocos"] += time.perf_counter() - t0
        if self.last_wav is not None:
            wav = wav[WAV_PAD:]
            front = wav[:WAV_OVERLAP]
            smooth = self.last_wav * DOWN + front * UP
            new = np.concatenate([smooth, wav[WAV_OVERLAP:-WAV_OVERLAP]])
        else:
            new = wav[:-WAV_OVERLAP]
        self.last_wav = wav[-WAV_OVERLAP:]
        return new.astype(np.float32)

    def process(self, samples: np.ndarray) -> np.ndarray:
        bn_new = self._encode_chunk(samples.astype(np.float32))
        if bn_new is None:
            return np.zeros(0, np.float32)
        if self.record:
            self.trace["bn"].append(bn_new)
        self.bn_buffer = bn_new if self.bn_buffer is None else np.concatenate([self.bn_buffer, bn_new], axis=0)
        need = CHUNK_SIZE + BLOCK_SIZE
        parts = []
        for _ in range(4):
            if self.bn_buffer.shape[0] < need:
                break
            cond = self.bn_buffer[:need]
            self.bn_buffer = self.bn_buffer[CHUNK_SIZE:]
            parts.append(self._decode_mel(self._vc_step(cond)))
        if not parts:
            return np.zeros(0, np.float32)
        out = np.concatenate(parts)
        if self.record:
            self.trace["wav"].append(out)
        return out
