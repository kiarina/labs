"""Measure official Mage-VL static-image inference on this Mac.

Loads microsoft/Mage-VL at a pinned revision with the official
processing/generation flow of mage_vl/inference_base.py, then times
greedy generation over multiple runs.
"""

import argparse
import json
import resource
import time

import torch
from PIL import Image
from transformers import AutoModelForCausalLM, AutoProcessor

REVISION = "d88b153285f1633a61b2f693c59c8576693af185"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--question", default="Describe this image.")
    parser.add_argument("--max-new-tokens", type=int, default=64)
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()

    t0 = time.perf_counter()
    processor = AutoProcessor.from_pretrained(
        "microsoft/Mage-VL", revision=REVISION, trust_remote_code=True
    )
    model = AutoModelForCausalLM.from_pretrained(
        "microsoft/Mage-VL",
        revision=REVISION,
        trust_remote_code=True,
        torch_dtype="auto",
        device_map="auto",
    ).eval()
    load_s = time.perf_counter() - t0

    messages = [{"role": "user", "content": [
        {"type": "image"}, {"type": "text", "text": args.question},
    ]}]
    text = processor.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )
    inputs = processor(
        text=[text],
        images=[Image.open(args.image).convert("RGB")],
        return_tensors="pt",
    )
    inputs = {
        k: (v.to(model.device) if hasattr(v, "to") else v)
        for k, v in inputs.items()
    }
    if "pixel_values" in inputs:
        inputs["pixel_values"] = inputs["pixel_values"].to(model.dtype)

    runs = []
    answer = None
    for _ in range(args.runs):
        t1 = time.perf_counter()
        with torch.inference_mode():
            output = model.generate(
                **inputs, max_new_tokens=args.max_new_tokens, do_sample=False
            )
        wall_s = time.perf_counter() - t1
        new_tokens = int(output.shape[1] - inputs["input_ids"].shape[1])
        runs.append({
            "wall_s": round(wall_s, 3),
            "new_tokens": new_tokens,
            "tokens_per_s": round(new_tokens / wall_s, 2),
        })
        answer = processor.tokenizer.decode(
            output[0, inputs["input_ids"].shape[1]:], skip_special_tokens=True
        )

    peak_rss_gb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**3
    print(json.dumps({
        "torch": torch.__version__,
        "device": str(model.device),
        "dtype": str(model.dtype),
        "revision": REVISION,
        "prompt_tokens": int(inputs["input_ids"].shape[1]),
        "load_s": round(load_s, 2),
        "runs": runs,
        "peak_rss_gb": round(peak_rss_gb, 2),
    }, indent=2))
    print("--- answer (last run) ---")
    print(answer.strip())


if __name__ == "__main__":
    main()
