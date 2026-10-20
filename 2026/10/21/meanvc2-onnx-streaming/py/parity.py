#!/usr/bin/env python3
"""Upstream PyTorch streaming (`runtime/run_rt.py`) vs the ONNX pipeline,
stage by stage, with the same ODE noise.

For each input the source is fed in 160 ms chunks (upstream realtime mode,
no flush). Both sides draw their noise from the same numpy generator, so the
only difference is the implementation. As a scale for the differences, the
upstream path is also run with a different noise seed (what two runs of the
same upstream code differ by).

Writes results/parity-*.json and the waveforms for listening to build/listen/.
"""
from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
import soundfile as sf
import torch

import inputs
from onnx_stream import CHUNK, VARIANTS, OnnxStreamingVC
from stream_vc import StreamingVC

HERE = Path(__file__).resolve().parent
LAB = HERE.parent


class Noise:
    def __init__(self, seed: int) -> None:
        self.rng = np.random.default_rng(seed)

    def __call__(self, n: int) -> np.ndarray:
        return self.rng.standard_normal((1, n, 80), dtype=np.float32)


def run_upstream(vc: StreamingVC, source: np.ndarray, seed: int) -> dict:
    runner = vc.runner
    vc.reset()
    runner.noise_fn = Noise(seed)
    run_rt = vc.run_rt
    trace = {"fbank": [], "bn": [], "mel": [], "wav": []}
    fbank = run_rt.kaldi.fbank
    encode, vc_step = type(runner)._encode_chunk, type(runner)._vc_step

    def rec_fbank(*a, **k):
        out = fbank(*a, **k)
        trace["fbank"].append(out.numpy().copy())
        return out

    def rec_encode(*a):
        out = encode(runner, *a)
        if out is not None:
            trace["bn"].append(out[0].numpy().copy())
        return out

    def rec_step(*a):
        out = vc_step(runner, *a)
        trace["mel"].append(out.numpy().copy())
        return out

    run_rt.kaldi.fbank = rec_fbank
    runner._encode_chunk, runner._vc_step = rec_encode, rec_step
    try:
        with torch.inference_mode():
            for start in range(0, len(source), CHUNK):
                chunk = source[start:start + CHUNK]
                if len(chunk) < CHUNK:
                    chunk = np.pad(chunk, (0, CHUNK - len(chunk)))
                y = vc.process(chunk)
                if len(y):
                    trace["wav"].append(y)
    finally:
        run_rt.kaldi.fbank = fbank
        del runner._encode_chunk, runner._vc_step
        runner.noise_fn = None
    return trace


def run_onnx(vc: OnnxStreamingVC, source: np.ndarray, seed: int) -> dict:
    vc.reset()
    vc.noise_fn = Noise(seed)
    vc.record = True
    for start in range(0, len(source), CHUNK):
        chunk = source[start:start + CHUNK]
        if len(chunk) < CHUNK:
            chunk = np.pad(chunk, (0, CHUNK - len(chunk)))
        vc.process(chunk)
    vc.record = False
    return vc.trace


def cat(trace, key):
    parts = trace[key]
    if key == "mel":
        return np.concatenate([p[0].T for p in parts], axis=0)
    return np.concatenate(parts, axis=0)


def compare(a: np.ndarray, b: np.ndarray) -> dict:
    n = min(len(a), len(b))
    a64, b64 = a[:n].astype(np.float64), b[:n].astype(np.float64)
    err = a64 - b64
    rel = float(np.linalg.norm(err) / (np.linalg.norm(b64) + 1e-30))
    return {"lengths": [int(len(a)), int(len(b))], "maxAbs": float(np.abs(err).max()),
            "relRms": rel, "snrDb": float(-20 * np.log10(rel + 1e-30)),
            "cosine": float((a64.ravel() @ b64.ravel()) / (np.linalg.norm(a64) * np.linalg.norm(b64) + 1e-30))}


def lsd_db(a: np.ndarray, b: np.ndarray) -> float:
    """Log-spectral distance (dB) of two waveforms: phase-blind, so it shows
    what a waveform difference means for the spectrum one hears."""
    import librosa
    n = min(len(a), len(b))
    A = np.abs(librosa.stft(a[:n], n_fft=512, hop_length=160)) + 1e-5
    B = np.abs(librosa.stft(b[:n], n_fft=512, hop_length=160)) + 1e-5
    voiced = B.sum(axis=0) > 1e-5 * B.shape[0] * 10
    d = 20 * np.log10(A / B)
    return float(np.sqrt((d[:, voiced] ** 2).mean(axis=0)).mean())


def compare_wav(a, b):
    row = compare(a, b)
    row["lsdDb"] = lsd_db(a, b)
    return row


def per_step_mel_error(a, b):
    """Relative error of each DiT step's mel (does it grow along the stream?)."""
    out = []
    for x, y in zip(a["mel"], b["mel"]):
        out.append(float(np.linalg.norm(x - y) / (np.linalg.norm(y) + 1e-30)))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--models", type=Path, default=LAB / "build/onnx")
    p.add_argument("--steps", type=int, nargs="+", default=[2, 3])
    p.add_argument("--cases", nargs="+", default=["asset", "kyoko", "long"])
    p.add_argument("--variants", nargs="+", default=["fp32", "int8"])
    p.add_argument("--seed", type=int, default=20261021)
    p.add_argument("--out", type=Path, default=LAB / "results/parity.json")
    p.add_argument("--listen", type=Path, default=LAB / "build/listen")
    a = p.parse_args()

    target = inputs.target_audio()
    up = StreamingVC(threads=1, model="120ms", steps=2)
    up.set_target(target)
    spk = up.runner.vc_spk_emb.numpy()
    ox = {v: OnnxStreamingVC(a.models, suffix=VARIANTS[v], threads=1) for v in a.variants}
    for v in ox.values():
        v.set_target(spk)

    report = {"machine": platform.machine(), "system": platform.system(), "torch": torch.__version__,
              "onnxruntime": ort.__version__, "seed": a.seed, "target": inputs.TARGET_DESCRIPTION, "cases": []}
    a.listen.mkdir(parents=True, exist_ok=True)
    for case in a.cases:
        source, desc = inputs.source(case)
        sf.write(a.listen / f"{case}_source.wav", source, 16000, subtype="FLOAT")
        for steps in a.steps:
            up.runner.ode_steps = steps
            ref = run_upstream(up, source, a.seed)
            other = run_upstream(up, source, a.seed + 1)
            row = {"case": case, "description": desc, "sourceSeconds": len(source) / 16000, "steps": steps,
                   "upstreamOtherNoise": {"mel": compare(cat(other, "mel"), cat(ref, "mel")),
                                          "wav": compare_wav(cat(other, "wav"), cat(ref, "wav"))}}
            sf.write(a.listen / f"{case}_s{steps}_torch.wav", cat(ref, "wav"), 16000, subtype="FLOAT")
            sf.write(a.listen / f"{case}_s{steps}_torch_seed2.wav", cat(other, "wav"), 16000, subtype="FLOAT")
            for name, vc in ox.items():
                vc.steps = steps
                got = run_onnx(vc, source, a.seed)
                row[name] = {k: compare(cat(got, k), cat(ref, k)) for k in ("fbank", "bn", "mel")}
                row[name]["wav"] = compare_wav(cat(got, "wav"), cat(ref, "wav"))
                errs = per_step_mel_error(got, ref)
                row[name]["melStepRelErr"] = {"first": errs[:3], "max": max(errs), "last": errs[-3:],
                                              "steps": len(errs)}
                sf.write(a.listen / f"{case}_s{steps}_onnx_{name}.wav", cat(got, "wav"), 16000, subtype="FLOAT")
            report["cases"].append(row)
            print(json.dumps({"case": case, "steps": steps,
                              **{n: {k: [round(v["snrDb"], 1), round(v.get("lsdDb", 0), 2)] for k, v in row[n].items()
                                     if isinstance(v, dict) and "snrDb" in v}
                                 for n in [*ox, "upstreamOtherNoise"]}}), flush=True)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
