"""Dump stage-by-stage outputs of the PyTorch Qwen3-TTS (qwen-tts 0.1.1) for the MLX comparison (mlx_compare.py).

Run from the lab directory with the PyTorch worker's environment:
    engines/qwen3_tts/.venv/bin/python bench/qwen3_tts_parity/torch_fixture.py [--device cpu --dtype float32]
Writes output/parity/torch-<device>-<dtype>.npz. The reference is sample speaker 1 (output/bench-reference-speaker1.wav).
"""

from __future__ import annotations

import argparse
from pathlib import Path

import librosa
import numpy as np
import torch
from qwen_tts import Qwen3TTSModel
from qwen_tts.core.models.modeling_qwen3_tts import mel_spectrogram

from common import LAB, REFERENCE, REFERENCE_TEXT, TEXT



class Captured(Exception):
    pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--dtype", default="float32")
    parser.add_argument("--generate", action="store_true", help="also sample one output (seed 0) and decode it")
    args = parser.parse_args()
    dtype = getattr(torch, args.dtype)
    tts = Qwen3TTSModel.from_pretrained(str(LAB / "models/Qwen3-TTS-12Hz-1.7B-Base"), device_map=args.device, dtype=dtype, attn_implementation="sdpa")
    model = tts.model
    out: dict[str, np.ndarray] = {}

    # 1. reference audio and its codes
    wav, sr = librosa.load(str(REFERENCE), sr=None, mono=True)
    assert sr == 24000
    out["wav"] = wav.astype(np.float32)
    ref_codes = model.speech_tokenizer.encode(wav, sr=sr).audio_codes[0]  # [T, 16]
    out["ref_codes"] = ref_codes.cpu().numpy()

    # 2. speaker embedding (mel + ECAPA)
    mel = mel_spectrogram(torch.from_numpy(wav).unsqueeze(0), n_fft=1024, num_mels=128, sampling_rate=24000,
                          hop_size=256, win_size=1024, fmin=0, fmax=12000).transpose(1, 2)
    out["mel"] = mel.numpy()
    spk = model.extract_speaker_embedding(wav, 24000)
    out["spk"] = spk.float().cpu().numpy()

    # 3. talker inputs for both layouts, and the first-step logits
    prompt = tts.create_voice_clone_prompt(ref_audio=str(REFERENCE), ref_text=REFERENCE_TEXT)
    captured = {}
    original_generate = model.talker.generate

    def capture(**kwargs):
        captured.update(kwargs)
        raise Captured

    model.talker.generate = capture
    for mode, non_streaming in (("ns", True), ("st", False)):
        try:
            tts.generate_voice_clone(text=TEXT, language="Japanese", voice_clone_prompt=prompt, non_streaming_mode=non_streaming)
        except Captured:
            pass
        embeds = captured["inputs_embeds"]
        out[f"{mode}_embeds"] = embeds.float().cpu().numpy()
        out[f"{mode}_trailing"] = captured["trailing_text_hidden"].float().cpu().numpy()
        with torch.inference_mode():
            result = model.talker(inputs_embeds=embeds, attention_mask=torch.ones(embeds.shape[:2], dtype=torch.long, device=embeds.device), use_cache=False)
        out[f"{mode}_logits"] = result.logits[:, -1].float().cpu().numpy()
        out[f"{mode}_hidden"] = result.past_hidden.float().cpu().numpy()
    out["tts_pad"] = captured["tts_pad_embed"].float().cpu().numpy()
    model.talker.generate = original_generate

    # code predictor, teacher-forced with one frame of the reference codes, from the non-streaming hidden state
    frame = ref_codes[10]
    out["cp_frame"] = frame.cpu().numpy()
    hidden = torch.from_numpy(out["ns_hidden"]).to(args.device, dtype)
    cp = model.talker.code_predictor
    parts = [hidden, model.talker.get_input_embeddings()(frame[None, :1].to(args.device))]
    cp_logits = []
    with torch.inference_mode():
        for k in range(model.talker.config.num_code_groups - 1):
            if k > 0:
                parts.append(cp.get_input_embeddings()[k - 1](frame[None, k : k + 1].to(args.device)))
            r = cp(inputs_embeds=torch.cat(parts, dim=1), use_cache=False)
            cp_logits.append(r.logits[:, -1].float().cpu().numpy())
    out["cp_logits"] = np.stack(cp_logits, axis=1)  # [1, 15, 2048]

    # 4. decoding the reference codes
    wavs, _ = model.speech_tokenizer.decode([{"audio_codes": ref_codes}])
    out["decoded_ref"] = wavs[0].astype(np.float32)

    if args.generate:
        torch.manual_seed(0)
        codes, _ = model.generate(input_ids=tts._tokenize_texts([tts._build_assistant_text(TEXT)]),
                                  ref_ids=[tts._tokenize_texts([tts._build_ref_text(REFERENCE_TEXT)])[0]],
                                  voice_clone_prompt=tts._prompt_items_to_voice_clone_prompt(prompt),
                                  languages=["Japanese"], non_streaming_mode=False, **tts._merge_generate_kwargs())
        out["gen_codes"] = codes[0].cpu().numpy()

    path = LAB / f"output/parity/torch-{args.device}-{args.dtype}.npz"
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez(path, **out)
    print("wrote", path, {k: v.shape for k, v in out.items()})


if __name__ == "__main__":
    with torch.inference_mode():
        main()
