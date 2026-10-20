#!/usr/bin/env python3
"""Fixtures for the benchmarks and the Flutter app.

- fixtures/target_spk.npy, fixtures/target_spk.json: the 256-d speaker
  embedding of the target reference (WavLM-Large + ECAPA, upstream encoder).
  This is the value the product would compute on the brain machine and ship.
- build/serve/: what the app downloads (models, sha256 manifest, the source
  PCM, the ODE noise and the expected ONNX output for the on-device parity)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np

import inputs
from onnx_stream import CHUNK, VARIANTS, OnnxStreamingVC
from parity import Noise

LAB = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--models", type=Path, default=LAB / "build/onnx")
    p.add_argument("--serve", type=Path, default=LAB / "build/serve")
    p.add_argument("--seed", type=int, default=20261021)
    p.add_argument("--steps", type=int, default=3)
    a = p.parse_args()

    spk_path = LAB / "fixtures/target_spk.npy"
    if not spk_path.exists():
        from stream_vc import StreamingVC
        vc = StreamingVC(threads=1, model="120ms", steps=2)
        vc.set_target(inputs.target_audio())
        spk = vc.runner.vc_spk_emb.numpy().astype(np.float32)
        spk_path.parent.mkdir(parents=True, exist_ok=True)
        np.save(spk_path, spk)
        (LAB / "fixtures/target_spk.json").write_text(json.dumps(
            {"description": inputs.TARGET_DESCRIPTION, "embedding": [float(x) for x in spk.ravel()]}) + "\n")
    spk = np.load(spk_path)

    serve = a.serve
    (serve / "models").mkdir(parents=True, exist_ok=True)
    manifest = {"models": {}, "fixtures": {}}
    for f in sorted(a.models.glob("*.onnx")):
        dst = serve / "models" / f.name
        if not dst.exists() or dst.stat().st_mtime < f.stat().st_mtime:
            shutil.copy2(f, dst)
        manifest["models"][f.name] = {"sha256": sha256(dst), "bytes": dst.stat().st_size}

    # On-device parity fixture: Kyoko sentence, the noise the pipeline draws, and
    # the Python ONNX Runtime outputs for fp32 and int8 with that noise.
    source, _ = inputs.source("kyoko")
    n_chunks = -(-len(source) // CHUNK)
    source = np.pad(source, (0, n_chunks * CHUNK - len(source))).astype(np.float32)
    fixtures = {"source.f32": source, "spk.f32": spk.ravel().astype(np.float32)}
    noise_rng = Noise(a.seed)
    noise = np.concatenate([noise_rng(16) for _ in range(n_chunks * 4)], axis=0)  # more than the steps drawn
    fixtures["noise.f32"] = noise.ravel().astype(np.float32)
    for variant in ("fp32", "int8"):
        vc = OnnxStreamingVC(a.models, suffix=VARIANTS[variant], threads=1, steps=a.steps)
        vc.set_target(spk)
        vc.noise_fn = Noise(a.seed)
        out = [vc.process(source[i:i + CHUNK]) for i in range(0, len(source), CHUNK)]
        fixtures[f"expected_{variant}_s{a.steps}.f32"] = np.concatenate(out).astype(np.float32)
    (serve / "fixtures").mkdir(parents=True, exist_ok=True)
    for name, arr in fixtures.items():
        path = serve / "fixtures" / name
        arr.astype("<f4").tofile(path)
        manifest["fixtures"][name] = {"sha256": sha256(path), "bytes": path.stat().st_size}
    manifest["seed"] = a.seed
    manifest["steps"] = a.steps
    (serve / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(serve / "manifest.json", LAB / "fixtures/manifest.json")
    print(json.dumps(manifest, indent=1))


if __name__ == "__main__":
    main()
