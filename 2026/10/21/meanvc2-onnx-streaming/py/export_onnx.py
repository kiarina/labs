#!/usr/bin/env python3
"""Export the streaming MeanVC2 parts (120ms model) to ONNX.

Five graphs, each one call of the upstream streaming loop
(`runtime/run_rt.py` `VCRunner`). Everything that is bookkeeping in upstream
(sample/frame caches, the sliding ASR window, BN interpolation, the ODE loop,
the vocoder cross-fade) stays in the host code (`onnx_stream.py`, the Dart app).

- fbank.onnx   frames [N, 400] (int16-scaled samples) -> log-mel [N, 80]
               (kaldi.fbank with the upstream parameters, as matmuls)
- asr.onnx     Fast-U2++ 160 ms: one sliding window [1, 19, 80] with offset and
               attention/conv caches -> BN [1, 4, 256] and the new caches
- gtm.onnx     speaker embedding [1, 256] -> global timbre memory k/v [1, 32, 256]
- dit.onnx     one mean-flow DiT evaluation on [1, 16, 80] with the per-layer
               KV cache as inputs/outputs (cache length 0..36 frames)
- vocos.onnx   mel [1, 80, T] -> waveform [1, 160 * (T - 1)] (ISTFT as matmuls
               and a transposed convolution)

The upstream modules are used as they are; only control flow that the ONNX
tracer would freeze (Python-int offsets, shape-dependent `if`) and ops without
an ONNX mapping (`F.rms_norm`, `irfft`, `fold`, `rfft`) are re-expressed here.
`--check` compares every graph with the upstream module on the same inputs.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn.functional as F
import torchaudio.compliance.kaldi as kaldi
from torch import nn

from stream_vc import StreamingVC

HERE = Path(__file__).resolve().parent
OPSET = 17


# ---------------------------------------------------------------------------
# fbank
# ---------------------------------------------------------------------------

class Fbank(nn.Module):
    """torchaudio.compliance.kaldi.fbank(frame_length=25, frame_shift=10,
    snip_edges=True, num_mel_bins=80, energy_floor=0.0, dither=0.0, 16 kHz) on
    frames that the host has already cut (400 samples each, every 160)."""

    def __init__(self) -> None:
        super().__init__()
        n, padded = 400, 512
        window = torch.hann_window(n, periodic=False, dtype=torch.float64).pow(0.85)
        k = torch.arange(padded // 2 + 1, dtype=torch.float64)
        t = torch.arange(n, dtype=torch.float64)  # only the first 400 of 512 are non-zero
        angle = 2 * math.pi * t[:, None] * k[None, :] / padded
        self.register_buffer("window", window.float())
        self.register_buffer("cos", torch.cos(angle).float())
        self.register_buffer("sin", (-torch.sin(angle)).float())
        mel, _ = kaldi.get_mel_banks(80, padded, 16000.0, 20.0, 0.0, 100.0, -500.0, 1.0)
        mel = F.pad(mel, (0, 1), mode="constant", value=0)  # [80, 257]
        self.register_buffer("mel", mel.t().contiguous().float())
        self.eps = torch.finfo(torch.float32).eps

    def forward(self, frames: torch.Tensor) -> torch.Tensor:
        x = frames - frames.mean(dim=1, keepdim=True)  # remove_dc_offset
        prev = torch.cat([x[:, :1], x[:, :-1]], dim=1)  # replicate pad
        x = (x - 0.97 * prev) * self.window
        re = x @ self.cos
        im = x @ self.sin
        power = re * re + im * im
        return torch.clamp(power @ self.mel, min=self.eps).log()


# ---------------------------------------------------------------------------
# ASR (TorchScript module, exported as is)
# ---------------------------------------------------------------------------

class Asr(nn.Module):
    def __init__(self, asr) -> None:
        super().__init__()
        self.asr = asr

    def forward(self, xs, offset, required_cache_size, att_cache, cnn_cache):
        return self.asr(xs, offset, required_cache_size, att_cache, cnn_cache)


# ---------------------------------------------------------------------------
# GTM
# ---------------------------------------------------------------------------

class Gtm(nn.Module):
    def __init__(self, dit) -> None:
        super().__init__()
        self.gtm = dit.gtm

    def forward(self, spks):
        return self.gtm(spks)


# ---------------------------------------------------------------------------
# DiT step
# ---------------------------------------------------------------------------

def _rms(x, weight, eps):
    return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + eps) * weight


def _rotate_half(x):
    shape = x.shape
    x = x.reshape(shape[0], shape[1], shape[2], -1, 2)
    x1, x2 = x[..., 0], x[..., 1]
    return torch.stack((-x2, x1), dim=-1).reshape(shape)


def _rope(t, cos, sin):
    n = t.shape[2]
    return t * cos[:, :, -n:, :] + _rotate_half(t) * sin[:, :, -n:, :]


class DiTStep(nn.Module):
    """One `DiT.forward(..., is_inference=True, cache=None, kv_cache=..., gtm_kv=...)`.

    `offset` is an int64 scalar tensor (upstream passes a Python int, which a
    trace would freeze). Cache inputs may have length 0 (the first chunk)."""

    def __init__(self, dit) -> None:
        super().__init__()
        self.dit = dit
        self.layers = []
        for block in dit.transformer_blocks:
            p = block.attn.processor
            self.layers.append((p.chunk_size, p.block_size, p.t_p, p.t_f))

    def _attention(self, attn, layer, x, cos, sin, k_cache, v_cache):
        chunk, block, t_p, t_f = layer
        b = x.shape[0]
        q = attn.to_q(x)
        k = attn.to_k(x)
        v = attn.to_v(x)
        head_dim = k.shape[-1] // attn.heads
        q = q.view(b, -1, attn.heads, head_dim).transpose(1, 2)
        k = k.view(b, -1, attn.heads, head_dim).transpose(1, 2)
        v = v.view(b, -1, attn.heads, head_dim).transpose(1, 2)
        q = _rms(q, attn.q_norm.weight, attn.q_norm.eps)
        k = _rms(k, attn.k_norm.weight, attn.k_norm.eps)
        k = torch.cat([k_cache, k], dim=2)
        v = torch.cat([v_cache, v], dim=2)
        # Upstream trims the future block, then keeps at most (t_p + 1) chunks.
        # Slicing from -max clamps like the shape-dependent `if` upstream.
        max_frames = (t_p + 1) * chunk
        new_k = k[:, :, :-block, :][:, :, -max_frames:, :]
        new_v = v[:, :, :-block, :][:, :, -max_frames:, :]
        q = _rope(q, cos, sin)
        k = _rope(k, cos, sin)
        seq = k.shape[2]
        idx = torch.arange(seq)
        ci = torch.div(idx, chunk, rounding_mode="floor")
        qi = ci[:, None]
        kj = ci[None, :]
        same = qi == kj
        prev = (kj >= (qi - t_p)) & (kj < qi)
        nxt = (kj == (qi + 1)) & ((idx % chunk)[None, :] < block * t_f)
        mask = (same | prev | nxt)[-q.shape[2]:, :]
        bias = torch.where(mask, torch.tensor(0.0), torch.tensor(float("-inf")))
        w = q @ k.transpose(-2, -1) * (1.0 / math.sqrt(head_dim)) + bias
        out = torch.softmax(w, dim=-1) @ v
        out = out.transpose(1, 2).reshape(b, -1, attn.heads * head_dim)
        return attn.to_out[0](out), new_k, new_v

    def forward(self, x, t, r, cond, spks, k_mem, v_mem, offset, *kv):
        d = self.dit
        t_emb = d.t_time_embed(t) + d.r_time_embed(r)
        timbre = d.temporal_timbre(cond, k_mem, v_mem)
        spk = spks.unsqueeze(1).expand(-1, cond.shape[1], -1)
        h = d.input_embed(x, timbre, spk)
        pos = torch.arange(offset + h.shape[1]).to(torch.float32)
        freqs = pos[:, None] * d.rotary_embed.inv_freq[None, :]
        freqs = torch.stack((freqs, freqs), dim=-1).reshape(1, 1, pos.shape[0], -1)
        cos, sin = freqs.cos(), freqs.sin()
        new_kv = []
        for i, block in enumerate(d.transformer_blocks):
            norm, gate_msa, shift_mlp, scale_mlp, gate_mlp = block.attn_norm(h, emb=t_emb)
            a, nk, nv = self._attention(block.attn, self.layers[i], norm, cos, sin, kv[2 * i], kv[2 * i + 1])
            h = h + gate_msa.unsqueeze(1) * a
            norm = block.ff_norm(h) * (1 + scale_mlp[:, None]) + shift_mlp[:, None]
            h = h + gate_mlp.unsqueeze(1) * block.ff(norm)
            new_kv += [nk, nv]
        h = d.norm_out(h, t_emb)
        return (d.proj_out(h), *new_kv)


# ---------------------------------------------------------------------------
# Vocos
# ---------------------------------------------------------------------------

class VocosBackbone(nn.Module):
    """The TorchScript `VocosBackbone` (ConvNeXt, no AdaNorm) as an eager module
    with the same weights: a TorchScript submodule cannot be traced inside a
    traced wrapper, and exporting it on its own fails on its Optional argument."""

    def __init__(self, scripted) -> None:
        super().__init__()
        sd = {k: v.detach().clone() for k, v in scripted.state_dict().items()}
        dim, mels, kernel = sd["embed.weight"].shape
        self.embed = nn.Conv1d(mels, dim, kernel, padding=kernel // 2)
        self.norm = nn.LayerNorm(dim, eps=1e-6)
        n = len({k.split(".")[1] for k in sd if k.startswith("convnext.")})
        inner = sd["convnext.0.pwconv1.weight"].shape[0]
        self.convnext = nn.ModuleList()
        for _ in range(n):
            block = nn.Module()
            block.dwconv = nn.Conv1d(dim, dim, 7, padding=3, groups=dim)
            block.norm = nn.LayerNorm(dim, eps=1e-6)
            block.pwconv1 = nn.Linear(dim, inner)
            block.pwconv2 = nn.Linear(inner, dim)
            block.gamma = nn.Parameter(torch.zeros(dim))
            self.convnext.append(block)
        self.final_layer_norm = nn.LayerNorm(dim, eps=1e-6)
        self.load_state_dict(sd, strict=True)

    def forward(self, x):
        x = self.embed(x)
        x = self.norm(x.transpose(1, 2)).transpose(1, 2)
        for b in self.convnext:
            r = x
            y = b.dwconv(x).transpose(1, 2)
            y = b.pwconv2(F.gelu(b.pwconv1(b.norm(y))))
            x = r + (b.gamma * y).transpose(1, 2)
        return self.final_layer_norm(x.transpose(1, 2))


class Vocos(nn.Module):
    """`vocos.decode(mel)` with the `center` ISTFT (n_fft=640, hop=160,
    win=640) rewritten as irfft matmuls + a transposed-convolution overlap-add."""

    def __init__(self, vocos) -> None:
        super().__init__()
        self.backbone = VocosBackbone(vocos.backbone)
        w = vocos.head.out.weight
        self.out = nn.Linear(w.shape[1], w.shape[0])
        self.out.load_state_dict({"weight": w.detach().clone(), "bias": vocos.head.out.bias.detach().clone()})
        istft = vocos.head.istft
        assert istft.padding == "center"
        self.n_fft, self.hop = int(istft.n_fft), int(istft.hop_length)
        n = self.n_fft
        k = torch.arange(n // 2 + 1, dtype=torch.float64)
        t = torch.arange(n, dtype=torch.float64)
        angle = 2 * math.pi * k[:, None] * t[None, :] / n
        c = torch.full((n // 2 + 1, 1), 2.0, dtype=torch.float64)
        c[0] = 1.0
        c[-1] = 1.0
        window = istft.window.to(torch.float64)
        # irfft (imag of DC and Nyquist ignored, as torch) then the window.
        cr = c * torch.cos(angle) / n * window[None, :]
        ci = -c * torch.sin(angle) / n * window[None, :]
        ci[0] = 0
        ci[-1] = 0
        self.register_buffer("cr", cr.float())
        self.register_buffer("ci", ci.float())
        self.register_buffer("eye", torch.eye(n, dtype=torch.float32).unsqueeze(1))  # [n, 1, n]
        self.register_buffer("win_sq", (window ** 2).float().view(1, n, 1))

    def forward(self, mel):
        x = self.out(self.backbone(mel)).transpose(1, 2)
        mag, p = torch.chunk(x, 2, dim=1)
        mag = torch.clamp(torch.exp(mag), max=100.0)
        re = (mag * torch.cos(p)).transpose(1, 2)  # [1, T, 321]
        im = (mag * torch.sin(p)).transpose(1, 2)
        frames = (re @ self.cr + im @ self.ci).transpose(1, 2)  # [1, 640, T]
        y = F.conv_transpose1d(frames, self.eye, stride=self.hop)  # [1, 1, (T-1)*hop + n]
        env = F.conv_transpose1d(self.win_sq.expand(1, self.n_fft, frames.shape[2]), self.eye, stride=self.hop)
        pad = self.n_fft // 2
        y = y[:, 0, pad:-pad]
        env = env[:, 0, pad:-pad]
        return y / env


# ---------------------------------------------------------------------------

def _names(prefix, n):
    return [f"{prefix}{i}" for i in range(n)]


def export_all(out_dir: Path, vc: StreamingVC) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    runner = vc.runner
    dit = runner.vc
    depth = len(dit.transformer_blocks)
    heads = dit.transformer_blocks[0].attn.heads
    head_dim = dit.transformer_blocks[0].attn.inner_dim // heads
    info = {"opset": OPSET, "torch": torch.__version__, "files": {}}

    def save(name, module, args, inputs, outputs, axes):
        path = out_dir / f"{name}.onnx"
        with torch.inference_mode():
            torch.onnx.export(module, args, str(path), opset_version=OPSET, input_names=inputs,
                              output_names=outputs, dynamic_axes=axes, do_constant_folding=True)
        onnx.checker.check_model(str(path))
        info["files"][name] = {"inputs": inputs, "outputs": outputs, "bytes": path.stat().st_size}
        print(f"[export] {path.name} {path.stat().st_size / 1e6:.1f} MB", flush=True)

    save("fbank", Fbank().eval(), (torch.randn(14, 400) * 3000,), ["frames"], ["fbank"],
         {"frames": {0: "n"}, "fbank": {0: "n"}})

    asr_args = (torch.randn(1, 19, 80), torch.tensor(8, dtype=torch.int64), torch.tensor(8, dtype=torch.int64),
                torch.zeros(6, 4, 8, 128), torch.zeros(6, 1, 256, 8))
    save("asr", runner.asr, asr_args, ["xs", "offset", "required_cache_size", "att_cache", "cnn_cache"],
         ["bn", "new_att_cache", "new_cnn_cache"], None)

    save("gtm", Gtm(dit).eval(), (torch.randn(1, 256),), ["spks"], ["k_mem", "v_mem"], None)

    kv_in = []
    for i in range(depth):
        kv_in += [f"k_cache{i}", f"v_cache{i}"]
    kv_out = [f"new_{n}" for n in kv_in]
    cache = [torch.randn(1, heads, 12, head_dim) for _ in range(2 * depth)]
    dit_args = (torch.randn(1, 16, 80), torch.tensor([1.0]), torch.tensor([0.5]), torch.randn(1, 16, 256),
                torch.randn(1, 256), torch.randn(1, 32, 256), torch.randn(1, 32, 256),
                torch.tensor(24, dtype=torch.int64), *cache)
    axes = {n: {2: f"cache_len{i // 2}"} for i, n in enumerate(kv_in)}
    axes.update({n: {2: f"new_cache_len{i // 2}"} for i, n in enumerate(kv_out)})
    save("dit", DiTStep(dit).eval(), dit_args,
         ["x", "t", "r", "cond", "spks", "k_mem", "v_mem", "offset", *kv_in], ["u", *kv_out], axes)

    save("vocos", Vocos(runner.vocoder).eval(), (torch.randn(1, 80, 14),), ["mel"], ["wav"],
         {"mel": {2: "frames"}, "wav": {1: "samples"}})
    info["dit"] = {"depth": depth, "heads": heads, "headDim": head_dim,
                   "maxCache": [(l[2] + 1) * l[0] for l in DiTStep(dit).layers]}
    (out_dir / "export.json").write_text(json.dumps(info, indent=2) + "\n")
    return info


# ---------------------------------------------------------------------------
# per-graph checks against the upstream modules
# ---------------------------------------------------------------------------

def _diff(a, b):
    a = np.asarray(a, np.float64)
    b = np.asarray(b, np.float64)
    err = np.abs(a - b)
    return {"maxAbs": float(err.max()), "meanAbs": float(err.mean()), "refMaxAbs": float(np.abs(b).max()),
            "cosine": float((a.ravel() @ b.ravel()) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-30))}


def check_all(out_dir: Path, vc: StreamingVC, suffix: str = "") -> dict:
    runner = vc.runner
    dit = runner.vc
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    sess = {n: ort.InferenceSession(str(out_dir / f"{n}{suffix}.onnx"), so, providers=["CPUExecutionProvider"])
            for n in ("fbank", "asr", "gtm", "dit", "vocos")}
    g = torch.Generator().manual_seed(0)
    report = {}
    with torch.inference_mode():
        wav = torch.randn(1, 400 + 160 * 29, generator=g) * 0.1
        ref = kaldi.fbank(wav * 32768, frame_length=25, frame_shift=10, snip_edges=True, num_mel_bins=80,
                          energy_floor=0.0, dither=0.0, sample_frequency=16000)
        frames = (wav[0] * 32768).unfold(0, 400, 160).numpy()
        got = sess["fbank"].run(None, {"frames": frames})[0]
        report["fbank"] = _diff(got, ref.numpy())

        fb = ref[:19].unsqueeze(0)
        att, cnn = torch.zeros(6, 4, 8, 128), torch.zeros(6, 1, 256, 8)
        rows = []
        oatt, ocnn = att.numpy(), cnn.numpy()
        for step, off in enumerate((8, 12, 16, 20)):
            fb = ref[step:step + 19].unsqueeze(0)
            o, att, cnn = runner.asr(fb, torch.tensor(off), torch.tensor(8), att, cnn)
            go, oatt, ocnn = sess["asr"].run(None, {"xs": fb.numpy(), "offset": np.array(off, np.int64),
                                                    "required_cache_size": np.array(8, np.int64),
                                                    "att_cache": oatt, "cnn_cache": ocnn})
            rows.append(_diff(go, o.numpy()))
        report["asr"] = rows

        spk = runner.vc_spk_emb if getattr(runner, "vc_spk_emb", None) is not None else torch.randn(1, 256, generator=g)
        km, vm = dit.gtm(spk)
        gk, gv = sess["gtm"].run(None, {"spks": spk.numpy()})
        report["gtm"] = [_diff(gk, km.numpy()), _diff(gv, vm.numpy())]

        # Same sequence of calls as the streaming loop: caches 0 -> 12 -> 24 -> 36.
        kv_ref = None
        kv_onnx = [np.zeros((1, 2, 0, 64), np.float32) for _ in range(8)]
        rows = []
        for step in range(5):
            x = torch.randn(1, 16, 80, generator=g)
            cond = torch.randn(1, 16, 256, generator=g)
            t, r = torch.tensor([1.0]), torch.tensor([0.5])
            u, kv_ref = dit(x, t, r, cache=None, cond=cond, spks=spk, offset=12 * step, is_inference=True,
                            kv_cache=kv_ref, gtm_kv=(km, vm))
            feed = {"x": x.numpy(), "t": t.numpy(), "r": r.numpy(), "cond": cond.numpy(), "spks": spk.numpy(),
                    "k_mem": km.numpy(), "v_mem": vm.numpy(), "offset": np.array(12 * step, np.int64)}
            for i in range(4):
                feed[f"k_cache{i}"], feed[f"v_cache{i}"] = kv_onnx[2 * i], kv_onnx[2 * i + 1]
            outs = sess["dit"].run(None, feed)
            kv_onnx = outs[1:]
            row = _diff(outs[0], u.numpy())
            row["cacheLen"] = [int(kv_onnx[2 * i].shape[2]) for i in range(4)]
            row["cacheLenRef"] = [int(kv_ref[i][0].shape[2]) for i in range(4)]
            row["cacheMaxAbs"] = max(float(np.abs(kv_onnx[2 * i] - kv_ref[i][0].numpy()).max()) for i in range(4))
            rows.append(row)
        report["dit"] = rows

        rows = []
        for frames_n in (12, 14):
            mel = torch.rand(1, 80, frames_n, generator=g) * 0.8
            ref_wav = runner.vocoder.decode(mel)
            got = sess["vocos"].run(None, {"mel": mel.numpy()})[0]
            row = _diff(got, ref_wav.numpy())
            row["frames"] = frames_n
            row["samples"] = int(got.shape[-1])
            rows.append(row)
        report["vocos"] = rows
    return report


def quantize_int8(out_dir: Path) -> dict:
    from onnxruntime.quantization import QuantType, quantize_dynamic
    sizes = {}
    for name in ("asr", "dit", "vocos"):
        src = out_dir / f"{name}.onnx"
        dst = out_dir / f"{name}.int8.onnx"
        # The ISTFT bases (`cr`, `ci`) are fixed DFT matrices, not weights, and the
        # Vocos head (`/out`) gives log-magnitude and phase: quantizing them
        # destroys the waveform (cosine 0.14-0.49 in the first attempt).
        exclude = ["/MatMul", "/MatMul_1", "/out/MatMul"] if name == "vocos" else []
        quantize_dynamic(str(src), str(dst), weight_type=QuantType.QInt8, op_types_to_quantize=["MatMul", "Gemm"],
                         nodes_to_exclude=exclude, per_channel=True)
        sizes[name] = dst.stat().st_size
        print(f"[int8] {dst.name} {dst.stat().st_size / 1e6:.1f} MB", flush=True)
    for name in ("fbank", "gtm"):
        (out_dir / f"{name}.int8.onnx").write_bytes((out_dir / f"{name}.onnx").read_bytes())
    return sizes


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, default=HERE.parent / "build/onnx")
    p.add_argument("--skip-export", action="store_true")
    p.add_argument("--int8", action="store_true")
    p.add_argument("--report", type=Path, default=HERE.parent / "results/export-check.json")
    a = p.parse_args()
    vc = StreamingVC(threads=1, model="120ms", steps=2)
    info = {}
    if not a.skip_export:
        info = export_all(a.out, vc)
    report = {"export": info, "fp32": check_all(a.out, vc)}
    if a.int8:
        report["int8Bytes"] = quantize_int8(a.out)
        report["int8"] = check_all(a.out, vc, ".int8")
    a.report.parent.mkdir(parents=True, exist_ok=True)
    a.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "export"}, indent=1)[:4000])


if __name__ == "__main__":
    main()
