from __future__ import annotations

import hashlib
import json
import os
import platform
import statistics
import subprocess
import time
from datetime import UTC, datetime
from importlib.metadata import version
from pathlib import Path
from typing import Any

import psutil
from huggingface_hub import snapshot_download


MODEL_ID = "mlx-community/Laguna-S-2.1-oQ2e"
MODEL_REVISION = "d3c0a22416617c6ccff1ff1c7bcd896d1ec92e8f"
HARNESS_URL = "https://github.com/tanishq-dubey/macos-laguna-s2.1"
HARNESS_REVISION = "2c2e55dda49fb28f8901bb993f6318e09c2b0aa2"
SEED = 20260721
OUTPUT = Path("output")


def command_output(*args: str) -> str | None:
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def swap_bytes() -> int | None:
    text = command_output("sysctl", "-n", "vm.swapusage")
    if not text:
        return None
    # Example: total = 4096.00M  used = 123.25M  free = 3972.75M
    try:
        value = text.split("used =", 1)[1].split()[0]
        units = {"K": 1024, "M": 1024**2, "G": 1024**3}
        return round(float(value[:-1]) * units[value[-1]])
    except (IndexError, KeyError, ValueError):
        return None


def memory_snapshot() -> dict[str, Any]:
    vm = psutil.virtual_memory()
    return {
        "available_bytes": vm.available,
        "used_bytes": vm.used,
        "percent": vm.percent,
        "swap_used_bytes": swap_bytes(),
        "memory_pressure": command_output("memory_pressure", "-Q"),
    }


def machine_metadata() -> dict[str, Any]:
    return {
        "machine_model": command_output("sysctl", "-n", "hw.model"),
        "chip": command_output("sysctl", "-n", "machdep.cpu.brand_string"),
        "memory_bytes": int(command_output("sysctl", "-n", "hw.memsize") or 0),
        "macos": command_output("sw_vers", "-productVersion"),
        "macos_build": command_output("sw_vers", "-buildVersion"),
        "architecture": platform.machine(),
        "python": platform.python_version(),
        "power": command_output("pmset", "-g", "batt"),
        "packages": {
            name: version(name)
            for name in ("huggingface-hub", "mlx", "mlx-vlm", "psutil", "transformers")
        },
    }


def render_prompt(tokenizer: Any, messages: list[dict[str, str]]) -> str:
    return tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        add_generation_prompt=True,
        enable_thinking=False,
    )


def prompt_token_count(tokenizer: Any, messages: list[dict[str, str]]) -> int:
    prompt = render_prompt(tokenizer, messages)
    if callable(tokenizer):
        encoded = tokenizer(prompt, add_special_tokens=True)
        input_ids = encoded["input_ids"] if isinstance(encoded, dict) else encoded.input_ids
    else:
        input_ids = tokenizer.encode(prompt, add_special_tokens=True)
    if input_ids and isinstance(input_ids[0], list):
        input_ids = input_ids[0]
    return len(input_ids)


def build_messages(tokenizer: Any, context_tokens: int, kind: str) -> tuple[list[dict[str, str]], int]:
    if kind == "prefill":
        needle = f"LAGUNA-{context_tokens:06d}-S21"
        prefix = f"Memorize this retrieval key: {needle}. The following material is irrelevant.\n"
        suffix = "\nEnd of irrelevant material. Return only the retrieval key that began this message:"
    elif kind == "decode":
        prefix = "This is fixed benchmark context. Read it silently.\n"
        suffix = (
            "\nContinue with a detailed numbered technical checklist. Keep generating until the token limit; "
            "do not conclude, summarize, or emit an end marker."
        )
    else:
        raise ValueError(f"unknown kind: {kind}")
    filler = " Laguna benchmark filler 0123456789."

    def candidate(repeats: int) -> list[dict[str, str]]:
        return [{"role": "user", "content": prefix + filler * repeats + suffix}]

    low, high = 0, max(1, context_tokens)
    while prompt_token_count(tokenizer, candidate(high)) < context_tokens:
        high *= 2
    while low + 1 < high:
        middle = (low + high) // 2
        if prompt_token_count(tokenizer, candidate(middle)) <= context_tokens:
            low = middle
        else:
            high = middle
    messages = candidate(low)
    return messages, prompt_token_count(tokenizer, messages)


def generate_once(
    model: Any,
    processor: Any,
    messages: list[dict[str, str]],
    *,
    max_tokens: int,
) -> dict[str, Any]:
    import mlx.core as mx
    from mlx_vlm import generate

    tokenizer = getattr(processor, "tokenizer", processor)
    prompt = render_prompt(tokenizer, messages)
    mx.random.seed(SEED)
    started = time.perf_counter()
    result = generate(
        model,
        processor,
        prompt=prompt,
        max_tokens=max_tokens,
        temperature=0.0,
        top_p=1.0,
        seed=SEED,
        prefill_step_size=2048,
        verbose=False,
    )
    elapsed = time.perf_counter() - started
    return {
        "elapsed_seconds": elapsed,
        "prompt_tokens": result.prompt_tokens,
        "generation_tokens": result.generation_tokens,
        "prompt_tps": result.prompt_tps,
        "generation_tps": result.generation_tps,
        "peak_memory_gb": result.peak_memory,
        "finish_reason": result.finish_reason,
        "output_sha256": hashlib.sha256(result.text.encode()).hexdigest(),
    }


def median(values: list[float]) -> float:
    if not values:
        raise ValueError("median requires at least one value")
    return statistics.median(values)


def main() -> None:
    import mlx.core as mx
    from mlx_vlm import load

    OUTPUT.mkdir(exist_ok=True)
    started_at = datetime.now(UTC)
    before_download = memory_snapshot()
    snapshot = Path(snapshot_download(MODEL_ID, revision=MODEL_REVISION))
    model_bytes = sum(path.stat().st_size for path in snapshot.glob("model-*.safetensors"))

    mx.clear_cache()
    mx.reset_peak_memory()
    before_load = memory_snapshot()
    load_started = time.perf_counter()
    model, processor = load(str(snapshot), lazy=False)
    load_seconds = time.perf_counter() - load_started
    load_peak_memory_gb = mx.get_peak_memory() / 1e9
    after_load = memory_snapshot()
    tokenizer = getattr(processor, "tokenizer", processor)

    decode_messages, decode_prompt_tokens = build_messages(tokenizer, 1024, "decode")

    # TTFT proxy definition: wall time around mlx_vlm.generate(max_tokens=1), from
    # immediately before the call until it returns the first generated token. Each
    # trial rebuilds the KV cache; it does not use prompt-cache reuse.
    mx.reset_peak_memory()
    ttft_first = generate_once(model, processor, decode_messages, max_tokens=1)
    ttft_warm = []
    for _ in range(5):
        ttft_warm.append(generate_once(model, processor, decode_messages, max_tokens=1))

    profile_runs: list[dict[str, Any]] = []
    for trial in range(1, 4):
        cases = []
        for case_id, context, kind, max_tokens in (
            ("context-16384", 16384, "prefill", 32),
            ("decode-256", 1024, "decode", 256),
        ):
            messages, actual_tokens = build_messages(tokenizer, context, kind)
            mx.clear_cache()
            mx.reset_peak_memory()
            before = memory_snapshot()
            metrics = generate_once(model, processor, messages, max_tokens=max_tokens)
            after = memory_snapshot()
            cases.append(
                {
                    "id": case_id,
                    "target_context_tokens": context,
                    "actual_context_tokens": actual_tokens,
                    "max_new_tokens": max_tokens,
                    "memory_before": before,
                    "memory_after": after,
                    **metrics,
                }
            )
        profile_runs.append({"trial": trial, "cases": cases})

    prefill = [run["cases"][0] for run in profile_runs]
    decode = [run["cases"][1] for run in profile_runs]
    record = {
        "schema_version": 1,
        "started_at": started_at.isoformat(),
        "finished_at": datetime.now(UTC).isoformat(),
        "purpose": "performance-only; no agent tasks or generated-code execution",
        "source_harness": {"url": HARNESS_URL, "revision": HARNESS_REVISION},
        "model": {
            "id": MODEL_ID,
            "revision": MODEL_REVISION,
            "snapshot_path_redacted": True,
            "safetensor_bytes": model_bytes,
        },
        "machine": machine_metadata(),
        "process": {"pid": os.getpid(), "nice": os.nice(0)},
        "memory": {
            "before_download": before_download,
            "before_load": before_load,
            "after_load": after_load,
            "after_benchmark": memory_snapshot(),
        },
        "load": {"seconds": load_seconds, "mlx_peak_memory_gb": load_peak_memory_gb},
        "ttft_definition": (
            "Wall time around mlx_vlm.generate(max_tokens=1) for the standardized 1K decode prompt; "
            "the timer begins immediately before generate and ends when the call returns one token. "
            "The first trial is the first inference request after lazy=False load. Five warm trials follow; "
            "each rebuilds KV state and uses no prompt-cache reuse."
        ),
        "ttft": {
            "actual_prompt_tokens": decode_prompt_tokens,
            "first_request": ttft_first,
            "warm_trials": ttft_warm,
            "warm_elapsed_median_seconds": median([x["elapsed_seconds"] for x in ttft_warm]),
        },
        "profile": {
            "description": "Upstream quant profile, repeated three times after TTFT warm-up",
            "runs": profile_runs,
            "summary": {
                "prefill_prompt_tps_median": median([x["prompt_tps"] for x in prefill]),
                "decode_generation_tps_median": median([x["generation_tps"] for x in decode]),
                "peak_memory_gb_max": max(x["peak_memory_gb"] for x in prefill + decode),
            },
        },
    }
    destination = OUTPUT / "raw-results.json"
    destination.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record["profile"]["summary"], indent=2))
    print(f"load_seconds={load_seconds:.3f}")
    print(f"ttft_first_seconds={ttft_first['elapsed_seconds']:.3f}")
    print(f"ttft_warm_median_seconds={record['ttft']['warm_elapsed_median_seconds']:.3f}")
    print(destination)


if __name__ == "__main__":
    main()
