"""Generate with the PyTorch Qwen3-TTS as the web UI's worker does (MPS bf16), keeping the codes, for mlx_generate.py.

    engines/qwen3_tts/.venv/bin/python bench/qwen3_tts_parity/torch_generate.py
Writes output/parity/gen/torch-<text>-<seed>.wav and output/parity/gen/torch.json.
"""

import json

import numpy as np
import soundfile as sf
import torch
from qwen_tts import Qwen3TTSModel

from common import LAB, REFERENCE, REFERENCE_TEXT, SEEDS, TEXTS, code_stats

OUT = LAB / "output/parity/gen"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tts = Qwen3TTSModel.from_pretrained(str(LAB / "models/Qwen3-TTS-12Hz-1.7B-Base"), device_map="mps", dtype=torch.bfloat16, attn_implementation="sdpa")
    prompt = tts.create_voice_clone_prompt(ref_audio=str(REFERENCE), ref_text=REFERENCE_TEXT)
    model, kept = tts.model, {}
    generate = model.generate

    def keep(**kwargs):
        codes, hidden = generate(**kwargs)
        kept["codes"] = codes[0].cpu().numpy()
        return codes, hidden

    model.generate = keep
    rows = []
    for t, text in enumerate(TEXTS):
        for seed in SEEDS:
            torch.manual_seed(seed)
            wavs, sr = tts.generate_voice_clone(text=text, language="Japanese", voice_clone_prompt=prompt)
            name = f"torch-{t}-{seed}.wav"
            sf.write(OUT / name, wavs[0], sr)
            np.save(OUT / name.replace(".wav", ".npy"), kept["codes"])
            rows.append({"engine": "torch", "text": t, "seed": seed, "wav": name, "seconds": len(wavs[0]) / sr, **code_stats(kept["codes"])})
            print(rows[-1], flush=True)
    (OUT / "torch.json").write_text(json.dumps(rows, indent=1))


if __name__ == "__main__":
    with torch.inference_mode():
        main()
