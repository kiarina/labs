"""Generate with mlx-audio's Qwen3-TTS, with and without the worker's match_pytorch patch, and compare with PyTorch.

    engines/qwen3_tts_mlx/.venv/bin/python bench/qwen3_tts_parity/mlx_generate.py [--quantization bf16]
Run torch_generate.py first to include the PyTorch rows. Writes output/parity/gen/ and prints the table for the README.
Speaker similarity is the cosine of the model's own x-vector (the speaker encoder in the checkpoint, float32 here)
between each output and the reference: not an independent judge, but the same one for every engine.
"""

import argparse
import json
import os
import sys
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).parent))
from common import LAB, REFERENCE, REFERENCE_TEXT, SEEDS, TEXTS, code_stats  # noqa: E402

os.environ.setdefault("WORKER_REPLY_FD", str(os.open(os.devnull, os.O_WRONLY)))
sys.path.insert(0, str(LAB / "engines/qwen3_tts_mlx"))
import worker  # noqa: E402  (applies the patches)

OUT = LAB / "output/parity/gen"
SETTINGS = {  # name -> (layout, penalty)
    "mlx-audio": (False, False),
    "penalty 1.05": (False, True),
    "layout": (True, False),
    "match_pytorch": (True, True),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quantization", default="bf16")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    tts = worker.model(args.quantization)
    kept = {}
    decode = tts.speech_tokenizer.decode

    def keep(codes):
        kept["codes"] = np.array(codes[0])
        return decode(codes)

    tts.speech_tokenizer.decode = keep

    def xvector(audio):
        return np.array(tts.extract_speaker_embedding(mx.array(audio.astype(np.float32))).astype(mx.float32))[0]

    reference = xvector(sf.read(REFERENCE, dtype="float32")[0])
    rows = []
    for name, (layout, penalty) in SETTINGS.items():
        worker.match["layout"], worker.match["penalty"] = layout, penalty
        for t, text in enumerate(TEXTS):
            for seed in SEEDS:
                mx.random.seed(seed)
                audio = np.concatenate([np.array(r.audio) for r in tts.generate(text=text, lang_code="japanese", ref_audio=str(REFERENCE), ref_text=REFERENCE_TEXT)])
                codes = kept["codes"][worker.prime["codes"].shape[2] :]  # drop the reference codes in front
                wav = f"mlx-{args.quantization}-{name.replace(' ', '_')}-{t}-{seed}.wav"
                sf.write(OUT / wav, audio, tts.sample_rate)
                rows.append({"engine": f"MLX {args.quantization} {name}", "text": t, "seed": seed, "wav": wav, "seconds": len(audio) / tts.sample_rate, **code_stats(codes)})
                print(rows[-1], flush=True)
    torch_rows = OUT / "torch.json"
    if torch_rows.exists():
        rows += [dict(r, engine="PyTorch MPS bf16") for r in json.loads(torch_rows.read_text())]
    for r in rows:
        r["speaker_cos"] = float(np.dot(v := xvector(sf.read(OUT / r["wav"], dtype="float32")[0]), reference) / np.linalg.norm(v) / np.linalg.norm(reference))
    (OUT / f"mlx-{args.quantization}.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False))
    print("| Setting | Runs | Speaker cos (mean, min) | First-codebook repeats | Distinct ratio | Audio (mean) |")
    print("|---|---:|---:|---:|---:|---:|")
    for engine in dict.fromkeys(r["engine"] for r in rows):
        rs = [r for r in rows if r["engine"] == engine]
        m = lambda k: np.mean([r[k] for r in rs])
        print(f"| {engine} | {len(rs)} | {m('speaker_cos'):.3f}, {min(r['speaker_cos'] for r in rs):.3f} | {m('repeat_rate'):.3f} | {m('distinct_ratio'):.3f} | {m('seconds'):.2f} 秒 |")


if __name__ == "__main__":
    main()
