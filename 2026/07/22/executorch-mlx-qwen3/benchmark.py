from __future__ import annotations

import argparse
import json
import platform
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

import psutil
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from config import (
    BENCHMARK_PROMPT,
    MAX_NEW_TOKENS,
    MODEL_ID,
    MODEL_REVISION,
    OUTPUT_DIR,
    PERFORMANCE_TRIALS,
    PROMPTS,
    PTE_PATHS,
)


BACKENDS = ("mlx_bf16", "mlx_int4", "pytorch_mps_bf16")


class MemoryMonitor:
    def __init__(self, interval_seconds: float = 0.01) -> None:
        self.process = psutil.Process()
        self.interval_seconds = interval_seconds
        self.baseline = self.process.memory_info().rss
        self.peak = self.baseline
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._sample, daemon=True)

    def _sample(self) -> None:
        while not self._stop.wait(self.interval_seconds):
            self.peak = max(self.peak, self.process.memory_info().rss)

    def __enter__(self) -> "MemoryMonitor":
        self._thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.peak = max(self.peak, self.process.memory_info().rss)
        self._stop.set()
        self._thread.join()


def format_prompt(tokenizer: Any, prompt: str) -> torch.Tensor:
    messages = [{"role": "user", "content": prompt}]
    try:
        text = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
    except TypeError:
        text = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )
    return tokenizer.encode(text, return_tensors="pt")


def common_prefix_length(left: list[int], right: list[int]) -> int:
    count = 0
    for left_token, right_token in zip(left, right):
        if left_token != right_token:
            break
        count += 1
    return count


def summarize_trials(trials: list[dict[str, Any]]) -> dict[str, float]:
    prefill = [float(trial["prefill_seconds"]) for trial in trials]
    decode_rates = [
        float(trial["decode_tokens_per_second"])
        for trial in trials
        if trial["decode_tokens_per_second"] is not None
    ]
    total = [float(trial["total_seconds"]) for trial in trials]
    return {
        "prefill_seconds_median": statistics.median(prefill),
        "decode_tokens_per_second_median": statistics.median(decode_rates),
        "total_seconds_median": statistics.median(total),
    }


def generate_executorch(
    forward: Any,
    input_ids: torch.Tensor,
    eos_token_id: int | None,
    stop_on_eos: bool = True,
) -> dict[str, Any]:
    started = time.perf_counter()
    cache_position = torch.arange(input_ids.shape[1], dtype=torch.long)
    logits = forward.execute([input_ids, cache_position])[0]
    next_token = int(torch.argmax(logits[0, -1, :]).item())
    first_token_at = time.perf_counter()
    tokens = [next_token]

    decode_started = time.perf_counter()
    for _ in range(MAX_NEW_TOKENS - 1):
        if stop_on_eos and eos_token_id is not None and next_token == eos_token_id:
            break
        position = input_ids.shape[1] + len(tokens) - 1
        logits = forward.execute(
            [
                torch.tensor([[next_token]], dtype=torch.long),
                torch.tensor([position], dtype=torch.long),
            ]
        )[0]
        next_token = int(torch.argmax(logits[0, -1, :]).item())
        tokens.append(next_token)
    finished = time.perf_counter()

    decode_tokens = max(0, len(tokens) - 1)
    decode_seconds = finished - decode_started
    return {
        "tokens": tokens,
        "prefill_seconds": first_token_at - started,
        "decode_seconds": decode_seconds,
        "decode_tokens": decode_tokens,
        "decode_tokens_per_second": (
            decode_tokens / decode_seconds if decode_tokens else None
        ),
        "total_seconds": finished - started,
    }


def generate_pytorch(
    model: Any,
    input_ids: torch.Tensor,
    eos_token_id: int | None,
    stop_on_eos: bool = True,
) -> dict[str, Any]:
    device_input = input_ids.to("mps")
    attention_mask = torch.ones_like(device_input)
    started = time.perf_counter()
    with torch.inference_mode():
        outputs = model(
            input_ids=device_input,
            attention_mask=attention_mask,
            use_cache=True,
        )
        next_token = int(torch.argmax(outputs.logits[0, -1, :]).item())
        past_key_values = outputs.past_key_values
        torch.mps.synchronize()
        first_token_at = time.perf_counter()
        tokens = [next_token]

        decode_started = time.perf_counter()
        for _ in range(MAX_NEW_TOKENS - 1):
            if stop_on_eos and eos_token_id is not None and next_token == eos_token_id:
                break
            attention_mask = torch.cat(
                [
                    attention_mask,
                    torch.ones((1, 1), dtype=attention_mask.dtype, device="mps"),
                ],
                dim=1,
            )
            outputs = model(
                input_ids=torch.tensor([[next_token]], device="mps"),
                attention_mask=attention_mask,
                past_key_values=past_key_values,
                use_cache=True,
            )
            past_key_values = outputs.past_key_values
            next_token = int(torch.argmax(outputs.logits[0, -1, :]).item())
            tokens.append(next_token)
        torch.mps.synchronize()
        finished = time.perf_counter()

    decode_tokens = max(0, len(tokens) - 1)
    decode_seconds = finished - decode_started
    return {
        "tokens": tokens,
        "prefill_seconds": first_token_at - started,
        "decode_seconds": decode_seconds,
        "decode_tokens": decode_tokens,
        "decode_tokens_per_second": (
            decode_tokens / decode_seconds if decode_tokens else None
        ),
        "total_seconds": finished - started,
    }


def worker_executorch(
    backend: str, tokenizer: Any
) -> tuple[float, list[dict[str, Any]], list[dict[str, Any]]]:
    from executorch.runtime import Runtime, Verification

    path = PTE_PATHS[backend]
    started = time.perf_counter()
    program = Runtime.get().load_program(str(path), verification=Verification.Minimal)
    load_seconds = time.perf_counter() - started

    warmup_ids = format_prompt(tokenizer, "答えを一語で: こんにちは")
    generate_executorch(
        program.load_method("forward"), warmup_ids, tokenizer.eos_token_id
    )

    quality_trials = []
    for prompt in PROMPTS:
        input_ids = format_prompt(tokenizer, prompt)
        trial = generate_executorch(
            program.load_method("forward"), input_ids, tokenizer.eos_token_id
        )
        trial.update(
            {
                "prompt": prompt,
                "input_tokens": input_ids.shape[1],
                "text": tokenizer.decode(trial["tokens"], skip_special_tokens=True),
            }
        )
        quality_trials.append(trial)

    benchmark_ids = format_prompt(tokenizer, BENCHMARK_PROMPT)
    performance_trials = []
    for _ in range(PERFORMANCE_TRIALS):
        performance_trials.append(
            generate_executorch(
                program.load_method("forward"),
                benchmark_ids,
                tokenizer.eos_token_id,
                stop_on_eos=False,
            )
        )
    return load_seconds, quality_trials, performance_trials


def worker_pytorch(
    tokenizer: Any,
) -> tuple[float, list[dict[str, Any]], list[dict[str, Any]]]:
    if not torch.backends.mps.is_available():
        raise SystemExit("MPS is not available")

    started = time.perf_counter()
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        revision=MODEL_REVISION,
        dtype=torch.bfloat16,
        low_cpu_mem_usage=True,
    ).eval().to("mps")
    torch.mps.synchronize()
    load_seconds = time.perf_counter() - started

    warmup_ids = format_prompt(tokenizer, "答えを一語で: こんにちは")
    generate_pytorch(model, warmup_ids, tokenizer.eos_token_id)

    quality_trials = []
    for prompt in PROMPTS:
        input_ids = format_prompt(tokenizer, prompt)
        trial = generate_pytorch(model, input_ids, tokenizer.eos_token_id)
        trial.update(
            {
                "prompt": prompt,
                "input_tokens": input_ids.shape[1],
                "text": tokenizer.decode(trial["tokens"], skip_special_tokens=True),
            }
        )
        quality_trials.append(trial)

    benchmark_ids = format_prompt(tokenizer, BENCHMARK_PROMPT)
    performance_trials = [
        generate_pytorch(
            model,
            benchmark_ids,
            tokenizer.eos_token_id,
            stop_on_eos=False,
        )
        for _ in range(PERFORMANCE_TRIALS)
    ]
    return load_seconds, quality_trials, performance_trials


def run_worker(backend: str, output: Path) -> None:
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, revision=MODEL_REVISION)
    with MemoryMonitor() as memory:
        if backend.startswith("mlx_"):
            load_seconds, quality_trials, performance_trials = worker_executorch(
                backend, tokenizer
            )
        else:
            load_seconds, quality_trials, performance_trials = worker_pytorch(tokenizer)

    result = {
        "backend": backend,
        "load_seconds": load_seconds,
        "memory": {
            "baseline_rss_bytes": memory.baseline,
            "peak_rss_bytes": memory.peak,
            "peak_delta_rss_bytes": memory.peak - memory.baseline,
        },
        "quality_trials": quality_trials,
        "performance_trials": performance_trials,
        "summary": summarize_trials(performance_trials),
    }
    if backend == "pytorch_mps_bf16":
        result["memory"]["mps_current_allocated_bytes"] = (
            torch.mps.current_allocated_memory()
        )
        result["memory"]["mps_driver_allocated_bytes"] = (
            torch.mps.driver_allocated_memory()
        )
        result["memory"]["mps_recommended_max_bytes"] = (
            torch.mps.recommended_max_memory()
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


def compare_tokens(results: dict[str, dict[str, Any]]) -> dict[str, Any]:
    reference_trials = results["pytorch_mps_bf16"]["quality_trials"]
    comparisons: dict[str, Any] = {}
    for backend in ("mlx_bf16", "mlx_int4"):
        cases = []
        for reference, candidate in zip(
            reference_trials, results[backend]["quality_trials"]
        ):
            reference_tokens = reference["tokens"]
            candidate_tokens = candidate["tokens"]
            prefix = common_prefix_length(reference_tokens, candidate_tokens)
            cases.append(
                {
                    "prompt": reference["prompt"],
                    "exact_token_match": reference_tokens == candidate_tokens,
                    "common_prefix_tokens": prefix,
                    "reference_tokens": len(reference_tokens),
                    "candidate_tokens": len(candidate_tokens),
                }
            )
        comparisons[backend] = {
            "exact_matches": sum(case["exact_token_match"] for case in cases),
            "cases": cases,
        }
    return comparisons


def run_all() -> None:
    missing = [str(path) for path in PTE_PATHS.values() if not path.exists()]
    if missing:
        raise SystemExit("Run export_models.py first; missing: " + ", ".join(missing))

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    results = {}
    for backend in BACKENDS:
        worker_output = OUTPUT_DIR / f"worker-{backend}.json"
        subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--worker",
                backend,
                "--output",
                str(worker_output),
            ],
            check=True,
        )
        results[backend] = json.loads(worker_output.read_text())

    report = {
        "model_id": MODEL_ID,
        "model_revision": MODEL_REVISION,
        "max_new_tokens": MAX_NEW_TOKENS,
        "performance_trials": PERFORMANCE_TRIALS,
        "benchmark_prompt": BENCHMARK_PROMPT,
        "prompts": PROMPTS,
        "results": results,
        "token_comparisons": compare_tokens(results),
        "environment": {
            "machine": platform.machine(),
            "platform": platform.platform(),
            "python": platform.python_version(),
            "torch": torch.__version__,
        },
    }
    report_path = OUTPUT_DIR / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    print("backend             load(s)  prefill(s)  decode(tok/s)  peak RSS delta")
    print("------------------  -------  ----------  -------------  --------------")
    for backend in BACKENDS:
        result = results[backend]
        summary = result["summary"]
        peak_gib = result["memory"]["peak_delta_rss_bytes"] / (1024**3)
        print(
            f"{backend:18}  {result['load_seconds']:7.3f}  "
            f"{summary['prefill_seconds_median']:10.3f}  "
            f"{summary['decode_tokens_per_second_median']:13.1f}  "
            f"{peak_gib:12.2f} GiB"
        )
    print(f"\nreport: {report_path}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", choices=BACKENDS)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    if args.worker:
        if args.output is None:
            parser.error("--output is required with --worker")
        run_worker(args.worker, args.output)
    else:
        run_all()


if __name__ == "__main__":
    main()
