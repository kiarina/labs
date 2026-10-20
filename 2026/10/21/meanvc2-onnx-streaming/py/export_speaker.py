#!/usr/bin/env python3
"""Export the reference-voice speaker encoder (WavLM-Large + ECAPA-TDNN, the
upstream `preprocess/models/ecapa_tdnn.py` with `wavlm_large_finetune.pth`) to
ONNX: waveform [1, T] (16 kHz float) -> embedding [1, 256].

Unlike the conversion graphs, these weights are CC BY-SA 3.0 (microsoft/UniSpeech),
so the exported file keeps that license (see the model card / NOTICE).

`--check` compares with the upstream encoder on references of several lengths.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import nn

import inputs
from stream_vc import StreamingVC

LAB = Path(__file__).resolve().parents[1]


class Speaker(nn.Module):
    """`ECAPA_TDNN.forward` for one waveform without s3prl's list/padding
    wrapper (whose Python lengths and `pad_sequence` a trace cannot follow).
    The hidden states are the same as s3prl's hooks: the input of each of the
    24 encoder layers, then the encoder output."""

    def __init__(self, ecapa) -> None:
        super().__init__()
        self.ecapa = ecapa
        expert = ecapa.feature_extract
        self.wavlm = expert.model
        self.normalize = bool(expert.cfg.normalize)
        self._hidden = []
        for layer in self.wavlm.encoder.layers:
            layer.register_forward_hook(lambda m, i, o: self._hidden.append(i[0].transpose(0, 1)))

    def forward(self, wav):
        e = self.ecapa
        if self.normalize:
            # F.layer_norm(wav, wav.shape) as s3prl, written out: a trace cannot
            # take the dynamic length as `normalized_shape`.
            mean = wav.mean(dim=1, keepdim=True)
            var = (wav - mean).pow(2).mean(dim=1, keepdim=True)
            wav = (wav - mean) / torch.sqrt(var + 1e-5)
        self._hidden = []
        features, _ = self.wavlm.extract_features(wav, padding_mask=None, mask=False)
        hidden = self._hidden + [features]
        x = torch.stack(hidden, dim=0)
        w = torch.softmax(e.feature_weight, dim=-1).view(-1, 1, 1, 1)
        x = (w * x).sum(dim=0).transpose(1, 2) + 1e-6
        x = e.instance_norm(x)
        out1 = e.layer1(x)
        out2 = e.layer2(out1)
        out3 = e.layer3(out2)
        out4 = e.layer4(out3)
        out = torch.cat([out2, out3, out4], dim=1)
        out = torch.relu(e.conv(out))
        out = e.bn(e.pooling(out))
        return e.linear(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, default=LAB / "build/onnx")
    p.add_argument("--report", type=Path, default=LAB / "results/export-speaker-check.json")
    a = p.parse_args()
    vc = StreamingVC(threads=4, model="120ms", steps=3)
    model = Speaker(vc.speaker).eval()
    path = a.out / "speaker.onnx"
    example = torch.from_numpy(inputs.target_audio()[None, : 16000 * 5].copy())
    with torch.inference_mode():
        torch.onnx.export(model, (example,), str(path), opset_version=17, input_names=["wav"], output_names=["embedding"],
                          dynamic_axes={"wav": {1: "samples"}}, do_constant_folding=True)
    onnx.checker.check_model(str(path))
    from onnxruntime.quantization import QuantType, quantize_dynamic
    q = a.out / "speaker.int8.onnx"
    quantize_dynamic(str(path), str(q), weight_type=QuantType.QInt8, op_types_to_quantize=["MatMul", "Gemm"], per_channel=True)

    target = inputs.target_audio()
    source, _ = inputs.source("kyoko")
    long, _ = inputs.source("long")
    refs = {"target 7.6 s": target, "target 3 s": target[: 3 * 16000], "kyoko 7.9 s": source, "long 20 s": long[: 20 * 16000]}
    so = ort.SessionOptions()
    so.intra_op_num_threads = 4
    report = {"bytes": {"fp32": path.stat().st_size, "int8": q.stat().st_size}, "rows": []}
    sessions = {"fp32": ort.InferenceSession(str(path), so), "int8": ort.InferenceSession(str(q), so)}
    for name, wav in refs.items():
        with torch.inference_mode():
            ref = vc.speaker(torch.from_numpy(wav[None].astype(np.float32))).numpy()  # upstream path
        row = {"reference": name}
        for v, s in sessions.items():
            got = s.run(None, {"wav": wav[None].astype(np.float32)})[0]
            row[v] = {"maxAbs": float(np.abs(got - ref).max()),
                      "cosine": float((got.ravel() @ ref.ravel()) / (np.linalg.norm(got) * np.linalg.norm(ref)))}
        report["rows"].append(row)
        print(json.dumps(row), flush=True)
    a.report.write_text(json.dumps(report, indent=2) + "\n")
    print(report["bytes"])


if __name__ == "__main__":
    main()
