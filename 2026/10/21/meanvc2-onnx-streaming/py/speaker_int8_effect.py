#!/usr/bin/env python3
"""What does the int8 speaker encoder change? Embedding time for the 7.6 s
reference and the converted Kyoko sentence with the int8 vs fp32 embedding
(same int8 conversion graphs, same noise)."""
import json, time, numpy as np, onnxruntime as ort, inputs
from onnx_stream import OnnxStreamingVC, VARIANTS
from parity import Noise, run_onnx, cat, compare_wav
so = ort.SessionOptions(); so.intra_op_num_threads = 4
t = inputs.target_audio()[None].astype(np.float32)
out = {}
for v in ("fp32", "int8"):
    s = ort.InferenceSession(f"../build/onnx/speaker{'' if v=='fp32' else '.int8'}.onnx", so)
    s.run(None, {"wav": t}); t0 = time.perf_counter(); e = s.run(None, {"wav": t})[0]; out[v] = (e, time.perf_counter() - t0)
vc = OnnxStreamingVC(__import__("pathlib").Path("../build/onnx"), suffix=VARIANTS["int8"], threads=1, steps=3)
src, _ = inputs.source("kyoko")
wav = {}
for v in ("fp32", "int8"):
    vc.set_target(out[v][0]); wav[v] = cat(run_onnx(vc, src, 20261021), "wav")
r = {"speakerSeconds7_6s": {v: round(out[v][1], 3) for v in out}, "conversionInt8EmbeddingVsFp32Embedding": compare_wav(wav["int8"], wav["fp32"])}
print(json.dumps(r))
json.dump(r, open("../results/speaker-int8-effect.json", "w"), indent=2)
