"""Evaluate one model on the Japanese, needle, and agent suites.

Usage: uv run python prepare.py && uv run python eval.py --model full4bit-plemmap --suites needle,agent,ja
"""

from __future__ import annotations

import argparse
import json
import platform
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
from datetime import UTC, datetime
from importlib.metadata import version
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
OUTPUT = HERE / "output"

PREPARED = OUTPUT / "models" / "full4bit-plemmap"

MODELS: dict[str, dict[str, str]] = {
    "reap288": {
        "repo": "sh0wie/Qwen3.8-Flash-Next-REAP-288-MLX-4bit",
        "revision": "668f31bcc56bf9400e64c9463445eee47597c2d9",
    },
    "full4bit": {
        "repo": "mlx-community/Qwen3.8-Flash-Next-4bit",
        "revision": "07b5dc6c54600a359b87f1e53e7adf6351c72a2c",
    },
    # Same weights as full4bit, loaded through prepare.py's external-PLE view.
    "full4bit-plemmap": {
        "repo": "mlx-community/Qwen3.8-Flash-Next-4bit",
        "revision": "07b5dc6c54600a359b87f1e53e7adf6351c72a2c",
        "prepared": "1",
    },
    "dense27b": {
        "repo": "mlx-community/Qwen3.8-27B-4bit",
        "revision": "10c35caafbb80f7dc6a7a432cdd11af10a6d4818",
    },
}

# Needle haystacks are fixed text, sized with the Qwen3.8-27B tokenizer so every
# model reads the same characters; each model's own token count is recorded.
REFERENCE_MODEL = "dense27b"
NEEDLE_TARGETS = (32_768, 131_072, 240_000)
NEEDLE_SEED = 20260924
PREFILL_STEP = 2048
APC_MEMORY_GB = 8
AGENT_MAX_STEPS = 24
AGENT_MAX_TOKENS = 4096


# --- text checks -------------------------------------------------------------


def clean_output(text: str) -> str:
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
    text = text.replace("<think>", "").replace("</think>", "")
    return unicodedata.normalize("NFKC", text).strip()


def _strip_fence(text: str) -> str:
    match = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", text, flags=re.S)
    return match.group(1) if match else text


def check(output: str, spec: dict[str, Any]) -> bool:
    kind = spec["type"]
    text = clean_output(output)
    norm = lambda s: unicodedata.normalize("NFKC", s)  # noqa: E731
    if kind == "all":
        return all(check(output, sub) for sub in spec["checks"])
    if kind == "contains_any":
        return any(norm(v) in text for v in spec["values"])
    if kind == "exact":
        return re.sub(r"\s+", "", text) == norm(spec["value"])
    if kind == "regex":
        return re.search(spec["pattern"], text) is not None
    if kind == "not_regex":
        return re.search(spec["pattern"], text) is None
    if kind == "max_chars":
        return len(re.sub(r"\s+", "", text)) <= spec["value"]
    if kind == "min_chars":
        return len(re.sub(r"\s+", "", text)) >= spec["value"]
    if kind == "last_line":
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        return bool(lines) and lines[-1] == spec["value"]
    if kind == "bullets":
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        prefix = norm(spec["prefix"])
        suffix = norm(spec["forbid_suffix"])
        return (
            len(lines) == spec["count"]
            and all(line.startswith(prefix) for line in lines)
            and not any(line.endswith(suffix) for line in lines)
        )
    if kind == "json_equals":
        try:
            return json.loads(_strip_fence(text)) == spec["value"]
        except json.JSONDecodeError:
            return False
    raise ValueError(f"unknown check: {kind}")


# --- needle haystack -----------------------------------------------------------

_PLACES = ["港町", "山里", "川辺の村", "丘の町", "湖畔の町", "峠の宿場", "海辺の集落", "盆地の町"]
_THINGS = ["青い木箱", "古い地図", "銅の鍵", "麻袋", "陶器の壺", "帳簿", "油紙の包み", "竹かご"]
_VERBS = ["運び込まれた", "数えられた", "記録された", "修理された", "売られた", "貸し出された"]
_KATAKANA = ["アオサギ", "カワセミ", "ハヤブサ", "ツバメ", "ヒバリ", "ミサゴ", "コマドリ", "ヤマガラ"]
NEEDLE_LABELS = ("北門", "中庭", "南塔")
DECOY_LABELS = ("東門", "西門", "地下室")
NEEDLE_DEPTHS = (0.1, 0.5, 0.9)


def filler_sentence(rng: random.Random, index: int) -> str:
    return (
        f"記録{index:06d}: {rng.choice(_PLACES)}の倉庫では、{rng.choice(_THINGS)}が"
        f"{rng.randint(2, 980)}個{rng.choice(_VERBS)}。担当者の番号は{rng.randint(100, 999)}番だった。"
    )


def needle_codes(seed: int) -> dict[str, str]:
    rng = random.Random(seed)
    labels = NEEDLE_LABELS + DECOY_LABELS
    words = rng.sample(_KATAKANA, len(labels))
    return {label: f"{word}-{rng.randint(1000, 9999)}" for label, word in zip(labels, words)}


def build_haystack(sentence_count: int, seed: int = NEEDLE_SEED) -> tuple[str, dict[str, str]]:
    """Deterministic haystack with three needles and three decoys."""
    rng = random.Random(seed)
    sentences = [filler_sentence(rng, i) for i in range(sentence_count)]
    codes = needle_codes(seed)
    inserts: list[tuple[float, str]] = []
    for label, depth in zip(NEEDLE_LABELS, NEEDLE_DEPTHS):
        inserts.append((depth, f"重要: {label}の合言葉は「{codes[label]}」である。"))
    for label, depth in zip(DECOY_LABELS, (0.3, 0.7, 0.95)):
        inserts.append((depth, f"参考: {label}の合言葉は「{codes[label]}」である。"))
    for depth, text in sorted(inserts, reverse=True):
        sentences.insert(int(len(sentences) * depth), text)
    answers = {label: codes[label] for label in NEEDLE_LABELS}
    return "\n".join(sentences), answers


NEEDLE_QUESTION = (
    "上の資料には、北門・中庭・南塔の合言葉がそれぞれ1つずつ書かれています。"
    "ほかの場所の合言葉は無視してください。"
    '{"北門": "...", "中庭": "...", "南塔": "..."} の形式の JSON だけを出力してください。'
)


def needle_messages(haystack: str) -> list[dict[str, str]]:
    return [{"role": "user", "content": f"以下は倉庫の記録です。\n\n{haystack}\n\n{NEEDLE_QUESTION}"}]


def score_needle(output: str, answers: dict[str, str]) -> dict[str, bool]:
    text = clean_output(output)
    try:
        parsed = json.loads(_strip_fence(text))
    except json.JSONDecodeError:
        parsed = {}
    if not isinstance(parsed, dict):
        parsed = {}
    return {label: str(parsed.get(label, "")).strip() == code for label, code in answers.items()}


# --- tool calls ------------------------------------------------------------------

_FUNC = re.compile(r"<function\s*=\s*([^>\s]+)\s*>(.*?)</function>", re.S)
_PARAM = re.compile(r"<parameter\s*=\s*([^>\s]+)\s*>\n?(.*?)\n?</parameter>", re.S)


def parse_tool_calls(text: str) -> list[dict[str, Any]]:
    """Qwen3.x Hermes/XML tool calls. Parameter values are kept as strings."""
    calls = []
    for name, body in _FUNC.findall(text):
        args = {m.group(1).strip(): m.group(2) for m in _PARAM.finditer(body)}
        calls.append({"name": name.strip(), "arguments": args})
    return calls


def visible_text(text: str) -> str:
    return re.sub(r"<tool_call>.*?(</tool_call>|$)", "", text, flags=re.S).strip()


TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List all files in the repository (relative paths).",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a UTF-8 text file from the repository.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Relative path"}},
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Overwrite (or create) a file with the given full content.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Relative path"},
                    "content": {"type": "string", "description": "Complete new file content"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_tests",
            "description": "Run the unit tests (python -m unittest discover -s tests) and return the output.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
]

AGENT_SYSTEM = (
    "あなたはソフトウェアエンジニアです。与えられたツールだけを使ってリポジトリを調べ、修正してください。"
    "ファイルを書き換えるときは write_file でファイル全体を書いてください。"
    "作業が終わったら、ツールを呼ばずに日本語で短く報告してください。"
)


def run_unittest(workdir: Path, timeout: int = 60) -> tuple[bool, str]:
    try:
        proc = subprocess.run(
            [sys.executable, "-m", "unittest", "discover", "-s", "tests"],
            cwd=workdir,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, "timeout"
    return proc.returncode == 0, (proc.stdout + proc.stderr)[-4000:]


def resolve_inside(workdir: Path, rel: str) -> Path:
    path = (workdir / rel.strip()).resolve()
    if workdir.resolve() not in path.parents and path != workdir.resolve():
        raise ValueError(f"path escapes the repository: {rel}")
    return path


def execute_tool(workdir: Path, name: str, args: dict[str, str]) -> str:
    try:
        if name == "list_files":
            files = sorted(
                str(p.relative_to(workdir))
                for p in workdir.rglob("*")
                if p.is_file() and "__pycache__" not in p.parts
            )
            return "\n".join(files)
        if name == "read_file":
            return resolve_inside(workdir, args["path"]).read_text(encoding="utf-8")
        if name == "write_file":
            path = resolve_inside(workdir, args["path"])
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(args["content"], encoding="utf-8")
            return f"wrote {len(args['content'])} characters to {args['path'].strip()}"
        if name == "run_tests":
            ok, out = run_unittest(workdir)
            return ("PASSED\n" if ok else "FAILED\n") + out
        return f"error: unknown tool {name}"
    except (KeyError, OSError, ValueError, UnicodeDecodeError) as exc:
        return f"error: {type(exc).__name__}: {exc}"


def grade_agent(task_dir: Path, workdir: Path) -> dict[str, Any]:
    original_tests = {
        p.relative_to(task_dir / "repo"): p.read_bytes() for p in (task_dir / "repo" / "tests").rglob("*.py")
    }
    tests_untouched = all(
        (workdir / rel).exists() and (workdir / rel).read_bytes() == data for rel, data in original_tests.items()
    )
    with tempfile.TemporaryDirectory() as tmp:
        graded = Path(tmp) / "repo"
        shutil.copytree(workdir, graded, ignore=shutil.ignore_patterns("__pycache__"))
        shutil.rmtree(graded / "tests", ignore_errors=True)
        shutil.copytree(task_dir / "repo" / "tests", graded / "tests")
        visible_ok, _ = run_unittest(graded)
        for hidden in (task_dir / "hidden").glob("*.py"):
            shutil.copy(hidden, graded / "tests" / hidden.name)
        all_ok, out = run_unittest(graded)
    return {
        "tests_untouched": tests_untouched,
        "visible_pass": visible_ok,
        "hidden_pass": all_ok,
        "success": tests_untouched and all_ok,
        "grader_tail": out[-1500:],
    }


# --- model runtime ---------------------------------------------------------------


class Runner:
    def __init__(
        self, key: str, use_apc: bool = True, prefill_step: int = PREFILL_STEP, apc_gb: float = APC_MEMORY_GB
    ) -> None:
        import mlx.core as mx
        from huggingface_hub import snapshot_download
        from mlx_vlm import load

        spec = MODELS[key]
        self.mx = mx
        self.key = key
        self.prefill_step = prefill_step
        self.apc_gb = apc_gb
        if spec.get("prepared"):
            if not (PREPARED / "ple-store.json").exists():
                raise SystemExit("run `uv run python prepare.py` first")
            self.path = str(PREPARED)
        else:
            self.path = snapshot_download(spec["repo"], revision=spec["revision"])
        mx.reset_peak_memory()
        t0 = time.perf_counter()
        self.model, self.processor = load(self.path)
        self.load_seconds = time.perf_counter() - t0
        self.load_peak_gb = mx.get_peak_memory() / 1e9
        self.tokenizer = getattr(self.processor, "tokenizer", self.processor)
        self.apc = None
        if use_apc:
            from mlx_vlm.apc import APCManager

            self.apc = APCManager(num_blocks=4096, block_size=16, overrides={"memory_max_gb": apc_gb})

    def render(self, messages: list[dict[str, Any]], tools: list | None = None) -> str:
        return self.tokenizer.apply_chat_template(
            messages,
            tools=tools,
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )

    def generate(
        self,
        messages: list[dict[str, Any]],
        *,
        max_tokens: int,
        tools: list | None = None,
        use_apc: bool = False,
    ) -> dict[str, Any]:
        from mlx_vlm import stream_generate

        prompt = self.render(messages, tools)
        self.mx.reset_peak_memory()
        kwargs: dict[str, Any] = {
            "max_tokens": max_tokens,
            "temperature": 0.0,
            "prefill_step_size": self.prefill_step,
        }
        if use_apc and self.apc is not None:
            kwargs.update(apc_manager=self.apc, apc_tenant="lab")
        t0 = time.perf_counter()
        ttft = None
        text = ""
        last = None
        for chunk in stream_generate(self.model, self.processor, prompt, **kwargs):
            if ttft is None:
                ttft = time.perf_counter() - t0
            text += chunk.text
            last = chunk
        elapsed = time.perf_counter() - t0
        return {
            "text": text,
            "prompt_tokens": getattr(last, "prompt_tokens", 0),
            "generation_tokens": getattr(last, "generation_tokens", 0),
            "cached_tokens": getattr(last, "cached_tokens", 0),
            "prompt_tps": getattr(last, "prompt_tps", 0.0),
            "generation_tps": getattr(last, "generation_tps", 0.0),
            "finish_reason": getattr(last, "finish_reason", None),
            "ttft_s": ttft,
            "elapsed_s": elapsed,
            "peak_gb": self.mx.get_peak_memory() / 1e9,
        }


# --- suites ----------------------------------------------------------------------


def run_ja(runner: Runner) -> dict[str, Any]:
    items = json.loads((DATA / "ja.json").read_text(encoding="utf-8"))
    results = []
    for item in items:
        out = runner.generate([{"role": "user", "content": item["prompt"]}], max_tokens=512)
        results.append({"id": item["id"], "category": item["category"], "pass": check(out["text"], item["check"]), **out})
        print(f"[ja] {item['id']} pass={results[-1]['pass']}", flush=True)
    by_cat: dict[str, list[bool]] = {}
    for r in results:
        by_cat.setdefault(r["category"], []).append(r["pass"])
    return {
        "score": sum(r["pass"] for r in results),
        "total": len(results),
        "by_category": {k: f"{sum(v)}/{len(v)}" for k, v in by_cat.items()},
        "items": results,
    }


def haystack_sizes() -> dict[int, int]:
    """Sentence count per target, measured with the reference tokenizer."""
    from huggingface_hub import snapshot_download
    from transformers import AutoTokenizer

    spec = MODELS[REFERENCE_MODEL]
    tok = AutoTokenizer.from_pretrained(snapshot_download(spec["repo"], revision=spec["revision"]))

    def count(n: int) -> int:
        text, _ = build_haystack(n)
        prompt = tok.apply_chat_template(
            needle_messages(text), tokenize=False, add_generation_prompt=True, enable_thinking=False
        )
        return len(tok.encode(prompt, add_special_tokens=False))

    per_sentence = count(1000) / 1000
    sizes = {}
    for target in NEEDLE_TARGETS:
        n = int(target / per_sentence)
        for _ in range(4):
            n = int(n * target / count(n))
        while count(n) > target:
            n -= 10
        sizes[target] = n
    return sizes


def run_needle(runner: Runner, targets: tuple[int, ...] = NEEDLE_TARGETS) -> dict[str, Any]:
    sizes_path = OUTPUT / "haystack_sizes.json"
    if sizes_path.exists():
        sizes = {int(k): v for k, v in json.loads(sizes_path.read_text()).items()}
    else:
        sizes = haystack_sizes()
        sizes_path.write_text(json.dumps(sizes, indent=2))
    results = []
    for target, n in sizes.items():
        if target not in targets:
            continue
        haystack, answers = build_haystack(n)
        out = runner.generate(needle_messages(haystack), max_tokens=128)
        hits = score_needle(out["text"], answers)
        results.append({"target_tokens": target, "sentences": n, "hits": hits, "score": sum(hits.values()), **out})
        print(f"[needle] {target} tokens={out['prompt_tokens']} hits={hits} prefill={out['prompt_tps']:.0f}tok/s", flush=True)
        runner.mx.clear_cache()
    return {"items": results}


def run_agent(runner: Runner) -> dict[str, Any]:
    results = []
    for task_dir in sorted(p for p in (DATA / "agent").iterdir() if p.is_dir()):
        task = json.loads((task_dir / "task.json").read_text(encoding="utf-8"))
        if runner.apc is not None:
            runner.apc.clear()
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp) / "repo"
            shutil.copytree(task_dir / "repo", workdir)
            messages: list[dict[str, Any]] = [
                {"role": "system", "content": AGENT_SYSTEM},
                {"role": "user", "content": task["instruction"]},
            ]
            steps = []
            final = ""
            stop = "max_steps"
            t0 = time.perf_counter()
            for step in range(AGENT_MAX_STEPS):
                out = runner.generate(messages, tools=TOOLS, max_tokens=AGENT_MAX_TOKENS, use_apc=True)
                calls = parse_tool_calls(out["text"])
                steps.append({k: v for k, v in out.items() if k != "text"} | {"calls": [c["name"] for c in calls]})
                if not calls:
                    final = out["text"]
                    stop = "answered" if out["finish_reason"] != "length" else "length"
                    break
                messages.append(
                    {
                        "role": "assistant",
                        "content": visible_text(out["text"]),
                        "tool_calls": [
                            {"type": "function", "function": {"name": c["name"], "arguments": c["arguments"]}}
                            for c in calls
                        ],
                    }
                )
                for call in calls:
                    messages.append({"role": "tool", "name": call["name"], "content": execute_tool(workdir, call["name"], call["arguments"])})
            grade = grade_agent(task_dir, workdir)
            results.append(
                {
                    "task": task_dir.name,
                    "stop": stop,
                    "steps": len(steps),
                    "elapsed_s": time.perf_counter() - t0,
                    "max_prompt_tokens": max((s["prompt_tokens"] for s in steps), default=0),
                    "peak_gb": max((s["peak_gb"] for s in steps), default=0.0),
                    "final": final,
                    "transcript": messages[2:],
                    "step_stats": steps,
                    **grade,
                }
            )
            print(f"[agent] {task_dir.name} success={grade['success']} steps={len(steps)} stop={stop}", flush=True)
    return {"score": sum(r["success"] for r in results), "total": len(results), "items": results}


SUITES = {"ja": run_ja, "needle": run_needle, "agent": run_agent}


# --- entry point -----------------------------------------------------------------


def command_output(*args: str) -> str | None:
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def environment() -> dict[str, Any]:
    return {
        "chip": command_output("sysctl", "-n", "machdep.cpu.brand_string"),
        "memory_bytes": int(command_output("sysctl", "-n", "hw.memsize") or 0),
        "macos": command_output("sw_vers", "-productVersion"),
        "python": platform.python_version(),
        "packages": {n: version(n) for n in ("mlx", "mlx-vlm", "transformers", "huggingface-hub")},
        "swap": command_output("sysctl", "-n", "vm.swapusage"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, choices=sorted(MODELS))
    parser.add_argument("--suites", default="ja,needle,agent")
    parser.add_argument("--prefill-step", type=int, default=PREFILL_STEP)
    parser.add_argument("--apc-gb", type=float, default=APC_MEMORY_GB)
    parser.add_argument("--needle-targets", default=",".join(map(str, NEEDLE_TARGETS)))
    parser.add_argument("--tag", default="", help="suffix for output files of non-default runs")
    args = parser.parse_args()
    targets = tuple(int(t) for t in args.needle_targets.split(","))
    suites = [s for s in args.suites.split(",") if s]
    OUTPUT.mkdir(exist_ok=True)
    runner = Runner(args.model, prefill_step=args.prefill_step, apc_gb=args.apc_gb)
    print(f"loaded {args.model} in {runner.load_seconds:.1f}s peak={runner.load_peak_gb:.1f}GB", flush=True)
    for suite in suites:
        started = datetime.now(UTC).isoformat()
        result = run_needle(runner, targets) if suite == "needle" else SUITES[suite](runner)
        record = {
            "model": args.model,
            **MODELS[args.model],
            "suite": suite,
            "started": started,
            "finished": datetime.now(UTC).isoformat(),
            "load_seconds": runner.load_seconds,
            "load_peak_gb": runner.load_peak_gb,
            "prefill_step": runner.prefill_step,
            "apc_memory_gb": runner.apc_gb,
            "environment": environment(),
            **result,
        }
        path = OUTPUT / f"{args.model}-{suite}{'-' + args.tag if args.tag else ''}.json"
        path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"wrote {path.relative_to(HERE)}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
