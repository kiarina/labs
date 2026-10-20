"""Compare mlx-audio 0.6.0's Qwen3-TTS with the PyTorch fixture (torch_fixture.py), stage by stage.

Run from the lab directory with the MLX worker's environment:
    engines/qwen3_tts_mlx/.venv/bin/python bench/qwen3_tts_parity/mlx_compare.py --dtype float32 --fixture output/parity/torch-cpu-float32.npz
--dtype float32 casts the mlx-community bf16 weights to float32 (the PyTorch weights are the same bf16 values);
--dtype bf16 keeps them as loaded (the runtime setting). Each stage gets the PyTorch side's input, so errors do not carry over.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import mlx.core as mx
import numpy as np
from huggingface_hub import snapshot_download
from mlx.utils import tree_map

sys.path.insert(0, str(Path(__file__).parent))
from common import LAB, REFERENCE, REFERENCE_TEXT, TEXT  # noqa: E402


def cos(a, b):
    a, b = np.ravel(a).astype(np.float64), np.ravel(b).astype(np.float64)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def report(name, ours, ref):
    ours, ref = np.asarray(ours, np.float64), np.asarray(ref, np.float64)
    if ours.shape != ref.shape:
        print(f"{name:34s} shape {ours.shape} vs {ref.shape}")
        return
    diff = np.abs(ours - ref)
    print(f"{name:34s} max|d| {diff.max():.3e}  mean|d| {diff.mean():.3e}  rel {np.linalg.norm(ours - ref) / np.linalg.norm(ref):.3e}  cos {cos(ours, ref):.6f}")


def softmax(x, t=0.9):
    x = np.asarray(x, np.float64) / t
    x = np.exp(x - x.max(-1, keepdims=True))
    return x / x.sum(-1, keepdims=True)


def logits_report(name, ours, ref):
    report(name, ours, ref)
    p, q = softmax(ref), softmax(ours)
    kl = float(np.sum(p * (np.log(p + 1e-30) - np.log(q + 1e-30)), axis=-1).max())
    top = [int(np.argmax(r) == np.argmax(o)) for r, o in zip(np.reshape(ref, (-1, ref.shape[-1])), np.reshape(ours, (-1, ours.shape[-1])))]
    print(f"{'':34s} KL(ref||ours, T=0.9) max {kl:.3e}  argmax same {sum(top)}/{len(top)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dtype", default="float32", choices=["float32", "bf16"])
    parser.add_argument("--fixture", default=str(LAB / "output/parity/torch-cpu-float32.npz"))
    args = parser.parse_args()
    f = dict(np.load(args.fixture))

    from mlx_audio.tts.utils import load_model
    from mlx_audio.utils import load_audio
    from mlx_audio.tts.models.qwen3_tts.qwen3_tts import mel_spectrogram

    if args.dtype == "float32":
        compile_ = mx.compile
        mx.compile = lambda fn, *a, **k: fn  # the vocoder is compiled at load; keep it a plain module so the cast applies
        model = load_model(snapshot_download("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision="a6eb4f68e4b056f1215157bb696209bc82a6db48"))
        mx.compile = compile_
        model.update(tree_map(lambda p: p.astype(mx.float32) if mx.issubdtype(p.dtype, mx.floating) else p, model.parameters()))
    else:
        model = load_model(snapshot_download("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision="a6eb4f68e4b056f1215157bb696209bc82a6db48"))
    dtype = mx.float32 if args.dtype == "float32" else mx.bfloat16
    print(f"fixture {Path(args.fixture).name}, MLX {args.dtype}")

    # 1. reference audio and codes
    wav = load_audio(str(REFERENCE), sample_rate=24000)
    report("1 wav (load_audio vs librosa)", np.array(wav), f["wav"])
    codes = np.array(model.speech_tokenizer.encode(mx.array(f["wav"])[None, None, :]))[0].T  # [T, 16]
    ref_codes = f["ref_codes"]
    if codes.shape == ref_codes.shape:
        same = codes == ref_codes
        print(f"{'1 ref codes differ at frames':34s} {np.where(~same.all(1))[0].tolist()}")
        print(f"{'1 ref codes (same wav)':34s} frames {codes.shape[0]}, all 16 same {int(same.all(1).sum())}/{codes.shape[0]}, "
              f"per codebook same {same.mean(0).round(3).tolist()}")
    else:
        print("1 ref codes shape", codes.shape, ref_codes.shape)

    # 2. speaker embedding
    mel = np.array(mel_spectrogram(mx.array(f["wav"])))
    report("2 mel", mel, f["mel"])
    spk_own = np.array(model.speaker_encoder(mx.array(mel).astype(dtype)).astype(mx.float32))
    spk_ref_mel = np.array(model.speaker_encoder(mx.array(f["mel"]).astype(dtype)).astype(mx.float32))
    report("2 x-vector (MLX mel)", spk_own, f["spk"][None])
    report("2 x-vector (PyTorch mel)", spk_ref_mel, f["spk"][None])

    # 3. talker inputs and logits
    embeds, trailing, tts_pad, _ = model._prepare_icl_generation_inputs(TEXT, mx.array(f["wav"]), REFERENCE_TEXT, "japanese")
    report("3 prefill embeds vs non-streaming", np.array(embeds.astype(mx.float32)), f["ns_embeds"])
    print(f"{'':34s} MLX prefill length {embeds.shape[1]}; PyTorch non-streaming {f['ns_embeds'].shape[1]}, streaming (default) {f['st_embeds'].shape[1]}")
    # the worker's patch (engines/qwen3_tts_mlx/worker.py, match_pytorch) against qwen-tts's default layout
    os.environ.setdefault("WORKER_REPLY_FD", str(os.open(os.devnull, os.O_WRONLY)))
    sys.path.insert(0, str(LAB / "engines/qwen3_tts_mlx"))
    import worker

    worker.match["layout"] = True
    st_embeds, st_trailing, _, _ = model._prepare_icl_generation_inputs(TEXT, mx.array(f["wav"]), REFERENCE_TEXT, "japanese")
    worker.match["layout"] = False
    report("3 patched embeds vs streaming", np.array(st_embeds.astype(mx.float32)), f["st_embeds"])
    same_codes, _ = worker._streaming_text_layout(model, embeds, TEXT, REFERENCE_TEXT, mx.array(ref_codes.T[None]))
    report("3 patched embeds (PyTorch codes)", np.array(same_codes.astype(mx.float32)), f["st_embeds"])
    report("3 patched trailing vs streaming", np.array(st_trailing.astype(mx.float32)), f["st_trailing"])
    logits, _ = model.talker(st_embeds, cache=model.talker.make_cache())
    logits_report("3 talker logits (patched, own codes)", np.array(logits[:, -1].astype(mx.float32)), f["st_logits"])
    logits, _ = model.talker(embeds, cache=model.talker.make_cache())
    logits_report("3 talker logits (mlx-audio layout)", np.array(logits[:, -1].astype(mx.float32)), f["st_logits"])

    for mode in ("ns", "st"):
        logits, hidden = model.talker(mx.array(f[f"{mode}_embeds"]).astype(dtype), cache=model.talker.make_cache())
        logits_report(f"3 talker logits ({mode}, same input)", np.array(logits[:, -1].astype(mx.float32)), f[f"{mode}_logits"])
        report(f"3 talker hidden ({mode})", np.array(hidden[:, -1:].astype(mx.float32)), f[f"{mode}_hidden"])

    cp = model.talker.code_predictor
    frame = mx.array(f["cp_frame"])
    parts = [mx.array(f["ns_hidden"]).astype(dtype), model.talker.get_input_embeddings()(frame[None, :1])]
    cp_logits = []
    for k in range(15):
        if k > 0:
            parts.append(cp.codec_embedding[k - 1](frame[None, k : k + 1]))
        out, _, _ = cp(mx.concatenate(parts, axis=1), cache=cp.make_cache(), generation_step=k)
        cp_logits.append(np.array(out[:, -1].astype(mx.float32)))
    logits_report("3 code predictor logits (15 steps)", np.stack(cp_logits, axis=1)[0], f["cp_logits"][0])

    # 4. decoder
    audio, lengths = model.speech_tokenizer.decode(mx.array(ref_codes)[None])
    audio = np.array(audio[0].astype(mx.float32))
    n = min(len(audio), len(f["decoded_ref"]))
    print(f"{'4 decode lengths':34s} MLX {len(audio)} (valid {int(lengths[0])}), PyTorch {len(f['decoded_ref'])}")
    report("4 decoded reference codes", audio[:n], f["decoded_ref"][:n])


if __name__ == "__main__":
    main()
