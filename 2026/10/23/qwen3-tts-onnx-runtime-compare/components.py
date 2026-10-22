"""Per-call latency of each onnx-community part, by precision, execution provider and thread count.

One generated frame (80 ms of audio) costs 1 talker step + 15 code-predictor calls + 1 residual_embed call, plus 1/25 of
a 25-frame decoder call (`published`) or 1/13 (`matched`, 12 frames of left context). Real time needs < 80 ms per frame.

Usage: uv run components.py --precision int4 --provider cpu --threads 0 8 4
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort

from download import onnx_community
from engines.common import LAB_DIR

# CoreML EP settings tried. MLProgram is the default format; NeuralNetwork is the older one; with
# RequireStaticInputShapes, only nodes whose input shapes are all fixed go to CoreML.
COREML = {
    "coreml": {"ModelFormat": "MLProgram", "MLComputeUnits": "ALL"},
    "coreml-nn": {"ModelFormat": "NeuralNetwork", "MLComputeUnits": "ALL"},
    "coreml-static": {"ModelFormat": "MLProgram", "MLComputeUnits": "ALL", "RequireStaticInputShapes": "1"},
}
PAST = 150  # a typical KV length mid-sentence (prefill ≈ 90 tokens + generated frames)


def feeds(session, name):
    rng = np.random.default_rng(0)
    out = {}
    for i in session.get_inputs():
        dtype = {"tensor(float)": np.float32, "tensor(float16)": np.float16, "tensor(int64)": np.int64}[i.type]
        if name == "talker_cache":
            if i.name == "inputs_embeds":
                out[i.name] = rng.standard_normal((1, 1, 2048)).astype(dtype)
            elif i.name == "position_ids":
                out[i.name] = np.full((3, 1, 1), PAST, np.int64)
            elif i.name == "attention_mask":
                out[i.name] = np.ones((1, PAST + 1), np.int64)
            else:
                out[i.name] = rng.standard_normal((1, i.shape[1], PAST, i.shape[3])).astype(dtype)
        elif dtype == np.int64:
            shape = [d if isinstance(d, int) else 1 for d in i.shape]
            out[i.name] = rng.integers(0, 2048, shape).astype(np.int64)
        else:
            shape = [d if isinstance(d, int) else (24_000 * 5 if d == "samples" else 1) for d in i.shape]
            out[i.name] = (0.1 * rng.standard_normal(shape)).astype(dtype)
    return out


def measure(path: Path, provider: str, threads: int, name: str, repeat: int) -> dict:
    options = ort.SessionOptions()
    options.log_severity_level = 3
    if threads:
        options.intra_op_num_threads = threads
    providers = ["CPUExecutionProvider"]
    if provider == "cuda":
        providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
    elif provider != "cpu":
        providers = [("CoreMLExecutionProvider", COREML[provider]), "CPUExecutionProvider"]
    started = time.perf_counter()
    try:
        session = ort.InferenceSession(str(path), options, providers=providers)
        feed = feeds(session, name)
        session.run(None, feed)
    except Exception as error:  # record and go on: CoreML rejects some graphs
        return {"error": f"{type(error).__name__}: {str(error).splitlines()[0][:200]}"}
    load = time.perf_counter() - started
    times = []
    for _ in range(repeat):
        t = time.perf_counter()
        session.run(None, feed)
        times.append(time.perf_counter() - t)
    return {"ms": round(float(np.median(times)) * 1000, 1), "load_s": round(load, 1)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--precision", default="int4")
    parser.add_argument("--provider", default="cpu", choices=["cpu", "cuda", *COREML])
    parser.add_argument("--threads", type=int, nargs="*", default=[0])
    parser.add_argument("--repeat", type=int, default=5)
    args = parser.parse_args()
    device = "cuda" if args.provider == "cuda" else "cpu"
    if device == "cuda":
        ort.preload_dlls()
    root = Path(onnx_community(args.precision, device)) / f"{device}_{args.precision}"
    results = []
    for threads in args.threads:
        row = {"precision": args.precision, "provider": args.provider, "threads": threads or "default"}
        for name in ["talker_cache", "code_predictor", "residual_embed", "tok_decoder", "tok_encoder"]:
            row[name] = measure(root / f"{name}.onnx", args.provider, threads, name, args.repeat)
        ok = all("ms" in row[n] for n in ["talker_cache", "code_predictor", "residual_embed", "tok_decoder"])
        if ok:
            frame = row["talker_cache"]["ms"] + 15 * row["code_predictor"]["ms"] + row["residual_embed"]["ms"]
            row["ms_per_frame_published"] = round(frame + row["tok_decoder"]["ms"] / 25, 1)
            row["ms_per_frame_matched"] = round(frame + row["tok_decoder"]["ms"] / 13, 1)
        print(json.dumps(row), flush=True)
        results.append(row)
    out = LAB_DIR / "output/components"
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{args.precision}-{args.provider}.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
