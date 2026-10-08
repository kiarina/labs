"""Let Codex fix fixture/calc.py with a kiapi chat model, through kiapi's Responses API.

    uv run run.py [--trials N] [--model qwen3.8-flash-next]

Each trial copies fixture/ to a fresh directory, starts a codex app-server tuned for a
local model (own CODEX_HOME, own model catalog, kiapi as the provider), sends one prompt,
then grades the directory by running the tests itself. Results go to results/.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

from openai_codex import CodexConfig
from openai_codex.client import CodexClient

LAB = Path(__file__).resolve().parent
RESULTS = LAB / "results"
CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
KIAPI = os.environ.get("KIAPI_BASE_URL", "http://127.0.0.1:8500").rstrip("/")
BASE_MODEL = "gpt-5.6-luna"  # the catalog entry we copy and adapt
PROMPT = (
    "The tests in this directory fail. Fix the bugs in calc.py so that "
    "`python3 -m unittest` passes. Do not change test_calc.py. "
    "Run the tests to confirm, then reply with a one-line summary."
)


def catalog(model: str) -> Path:
    cache = json.loads((CODEX_HOME / "models_cache.json").read_text())
    base = next(m for m in cache["models"] if m["slug"] == BASE_MODEL)
    entry = {**base, "slug": model, "display_name": model, "description": "kiapi local model",
             "tool_mode": None, "multi_agent_version": None, "apply_patch_tool_type": None,
             "use_responses_lite": False, "supports_search_tool": False, "experimental_supported_tools": [],
             "include_skills_usage_instructions": False, "include_apps_usage_instructions": False,
             "include_plugin_usage_instructions": False, "node_repl_disabled": True,
             "service_tiers": [], "additional_speed_tiers": [], "context_window": 200000, "max_context_window": 200000}
    path = Path(tempfile.mkdtemp(prefix="codex-kiapi-catalog-")) / "models.json"
    path.write_text(json.dumps({"models": [entry]}))
    return path


def overrides(model: str) -> tuple[str, ...]:
    o = [
        f'model_providers.kiapi={{name="kiapi", base_url="{KIAPI}/v1", wire_api="responses"}}',
        'model_provider="kiapi"',
        f'model="{model}"',
        f'model_catalog_json="{catalog(model)}"',
        'web_search="disabled"',
        "skills.include_instructions=false",
    ]
    for f in ["code_mode_host", "multi_agent", "apps", "plugins", "image_generation", "computer_use", "browser_use",
              "browser_use_external", "in_app_browser", "goals", "tool_suggest", "skill_search", "memories"]:
        o.append(f"features.{f}=false")
    return tuple(o)


def grade(cwd: Path) -> dict:
    tests = subprocess.run(["python3", "-m", "unittest", "-q"], cwd=cwd, capture_output=True, text=True, timeout=60)
    untouched = (cwd / "test_calc.py").read_text() == (LAB / "fixture" / "test_calc.py").read_text()
    return {"tests_pass": tests.returncode == 0, "tests_untouched": untouched,
            "tests_tail": (tests.stdout + tests.stderr).strip().splitlines()[-1:]}


def trial(model: str, index: int) -> dict:
    cwd = Path(tempfile.mkdtemp(prefix="codex-kiapi-task-"))
    for f in (LAB / "fixture").iterdir():
        shutil.copy(f, cwd / f.name)
    env = {**os.environ, "CODEX_HOME": tempfile.mkdtemp(prefix="codex-kiapi-home-")}
    client = CodexClient(config=CodexConfig(config_overrides=overrides(model), env=env, client_name="codex-on-kiapi"))
    t0 = time.time()
    client.start()
    client.initialize()
    thread = client.thread_start({"cwd": str(cwd), "ephemeral": True, "approvalPolicy": "never", "sandbox": "workspace-write"})
    turn = client.turn_start(thread.thread.id, PROMPT)
    turn_id = turn.turn.id
    client.register_turn_notifications(turn_id)
    steps: list[dict] = []
    usage = None
    status = error = None
    try:
        while True:
            n = client.next_turn_notification(turn_id)
            p = n.payload.model_dump(mode="json", by_alias=True) if hasattr(n.payload, "model_dump") else {}
            ms = int((time.time() - t0) * 1000)
            if n.method == "item/completed":
                item = p.get("item", {})
                if item.get("type") == "commandExecution":
                    steps.append({"type": "command", "command": item.get("command"), "exitCode": item.get("exitCode"),
                                  "output": (item.get("aggregatedOutput") or "")[-400:], "ms": ms})
                elif item.get("type") == "agentMessage":
                    steps.append({"type": "message", "text": item.get("text"), "ms": ms})
                elif item.get("type") not in ("userMessage", "reasoning"):
                    steps.append({"type": item.get("type"), "ms": ms})
            elif n.method == "thread/tokenUsage/updated":
                usage = p.get("tokenUsage")
            elif n.method == "error":
                error = p
            elif n.method == "turn/completed":
                status = p.get("turn", {}).get("status")
                error = p.get("turn", {}).get("error") or error
                break
    finally:
        client.unregister_turn_notifications(turn_id)
        client.close()
    result = {"trial": index, "model": model, "status": status, "error": error,
              "seconds": round(time.time() - t0, 1), "steps": steps, "usage": usage, **grade(cwd)}
    result["calc_py"] = (cwd / "calc.py").read_text()
    # Keep local temp paths out of the committed results.
    text = json.dumps(result, ensure_ascii=False)
    for path in (str(cwd.resolve()), str(cwd)):
        text = text.replace(path, "<task>")
    return json.loads(text)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trials", type=int, default=1)
    ap.add_argument("--model", default="qwen3.8-flash-next")
    args = ap.parse_args()
    health = json.loads(urllib.request.urlopen(f"{KIAPI}/health", timeout=10).read())
    print("kiapi:", health.get("status"), "queue_len", health.get("queue_len"))
    RESULTS.mkdir(exist_ok=True)
    runs = []
    for i in range(args.trials):
        r = trial(args.model, i)
        runs.append(r)
        print(json.dumps({k: r[k] for k in ("trial", "status", "seconds", "tests_pass", "tests_untouched")}),
              "commands:", sum(s["type"] == "command" for s in r["steps"]))
        (RESULTS / f"{args.model}.json").write_text(json.dumps(runs, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
