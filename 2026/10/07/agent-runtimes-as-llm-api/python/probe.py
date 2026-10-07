"""The same probe as src/codex.ts and src/claude.ts, with the Python SDKs.

    uv run probe.py codex --mock    # openai-codex (wraps codex app-server)
    uv run probe.py claude --mock   # claude-agent-sdk

Without --mock it sends the real request (uses the subscription). The prompt,
system prompt and tools come from ../fixture (node src/export-fixture.ts).
"""

from __future__ import annotations

import os
import sys

# Do not inherit a host Claude Code session (this may run inside one).
for _k in list(os.environ):
    if _k == "CLAUDECODE" or _k.startswith(("CLAUDE_CODE_", "ANTHROPIC_")) or _k == "CLAUDE_AGENT_SDK_VERSION":
        del os.environ[_k]

import asyncio
import json
import tempfile
import threading
import time
import tomllib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
FIXTURE = json.loads((LAB / "fixture" / "tools.json").read_text())
PROMPT = (LAB / "fixture" / "prompt.txt").read_text()
RESULTS = LAB / "results"
SYSTEM_PROMPT: str = FIXTURE["systemPrompt"]
TOOLS: list[dict] = FIXTURE["tools"]
MODEL = "gpt-6.1-sol"

_event_seq = 9000


def handle(name: str, args: dict) -> object:
    """What the app returns for a call (same as src/tools.ts)."""
    global _event_seq
    if name == "create_event":
        _event_seq += 1
        return {"event_id": f"evt_{_event_seq}", "status": "created"}
    if name == "send_message":
        return {"status": "sent", "recipients": len(args.get("to") or [])}
    if name == "get_team_members":
        return FIXTURE["members"]
    if name == "check_availability":
        return {"available": True}
    return {"error": f"{name} is not available in this test"}


# --- capture server ---------------------------------------------------------


def start_mock(name: str) -> tuple[str, ThreadingHTTPServer]:
    requests: list[dict] = []
    out = RESULTS / f"{name}-mock-requests.json"

    class H(BaseHTTPRequestHandler):
        def _record(self) -> None:
            n = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(n).decode() if n else ""
            try:
                body: object = json.loads(raw)
            except ValueError:
                body = raw
            requests.append({"method": self.command, "path": self.path, "body": body})
            out.write_text(json.dumps(requests, ensure_ascii=False, indent=2))
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"type":"error","error":{"type":"invalid_request_error","message":"mock: captured"}}')

        do_POST = do_HEAD = do_GET = _record

        def log_message(self, *_: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}", server


# --- codex ------------------------------------------------------------------


def codex_overrides() -> tuple[str, ...]:
    """Process-level `-c` overrides, as in src/codex.ts."""
    features = [
        "shell_tool", "unified_exec", "code_mode_host", "multi_agent", "apps", "plugins", "image_generation",
        "computer_use", "browser_use", "browser_use_external", "in_app_browser", "view_image", "sleep_tool",
        "goals", "tool_suggest", "skill_search", "hooks", "workspace_dependencies", "memories",
    ]
    o = [f"features.{f}=false" for f in features]
    o.append('web_search="disabled"')
    for k in ["include_environment_context", "include_permissions_instructions", "include_apps_instructions",
              "include_collaboration_mode_instructions", "skills.include_instructions"]:
        o.append(f"{k}=false")
    home = Path.home() / ".codex"
    for name in tomllib.loads((home / "config.toml").read_text()).get("mcp_servers", {}):
        o.append(f"mcp_servers.{name}.enabled=false")
    if "--default-catalog" not in sys.argv:
        cache = json.loads((home / "models_cache.json").read_text())
        base = next(m for m in cache["models"] if m["slug"] == MODEL)
        entry = {**base, "tool_mode": None, "multi_agent_version": None, "apply_patch_tool_type": None,
                 "supports_search_tool": False, "experimental_supported_tools": [],
                 "include_skills_usage_instructions": False, "include_apps_usage_instructions": False,
                 "include_plugin_usage_instructions": False, "node_repl_disabled": True}
        catalog = Path(tempfile.mkdtemp(prefix="llm-api-probe-catalog-")) / "models.json"
        catalog.write_text(json.dumps({"models": [entry]}))
        o.append(f'model_catalog_json="{catalog}"')
    return tuple(o)


def run_codex(mock: bool) -> dict:
    from openai_codex import CodexConfig
    from openai_codex.client import CodexClient

    url, server = start_mock("codex-py") if mock else (None, None)
    steps: list[dict] = []
    t0 = time.time()

    def on_request(method: str, params: dict | None) -> dict:
        # Server-initiated requests: the app's tools arrive here as item/tool/call.
        if method == "item/tool/call" and params:
            args = params.get("arguments") or {}
            steps.append({"type": "tool_call", "name": params["tool"], "args": args, "ms": int((time.time() - t0) * 1000)})
            out = handle(params["tool"], args)
            return {"contentItems": [{"type": "inputText", "text": json.dumps(out, ensure_ascii=False)}], "success": True}
        return {}

    client = CodexClient(
        config=CodexConfig(codex_bin=os.environ.get("CODEX_BIN"), config_overrides=codex_overrides(), client_name="llm-api-probe-py"),
        approval_handler=on_request,
    )
    client.start()
    client.initialize()
    params: dict = {
        "cwd": tempfile.mkdtemp(prefix="llm-api-probe-"),
        "ephemeral": True,
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "baseInstructions": SYSTEM_PROMPT,
        "model": MODEL,
        # Not in the SDK's typed ThreadStartParams (experimental); passed as a raw dict.
        "dynamicTools": [{"type": "function", **t} for t in TOOLS],
    }
    if url:
        params["config"] = {"model_providers": {"mock": {"name": "mock", "base_url": f"{url}/v1", "wire_api": "responses"}}}
        params["modelProvider"] = "mock"
    started = client.thread_start(params)
    turn = client.turn_start(started.thread.id, PROMPT)
    done = client.wait_for_turn_completed(turn.turn.id)
    final = done.model_dump(mode="json", by_alias=True)
    client.close()
    if server:
        server.shutdown()
    items = final.get("turn", {}).get("items") or []
    for it in items:
        if it.get("type") == "agentMessage":
            steps.append({"type": "message", "text": it.get("text"), "ms": int((time.time() - t0) * 1000)})
    return {"runtime": "codex-py", "mock": mock, "model": MODEL, "steps": steps,
            "error": final.get("turn", {}).get("error"), "totalMs": int((time.time() - t0) * 1000)}


# --- claude -----------------------------------------------------------------


async def run_claude(mock: bool) -> dict:
    from claude_agent_sdk import ClaudeAgentOptions, create_sdk_mcp_server, query, tool

    url, server = start_mock("claude-py") if mock else (None, None)
    steps: list[dict] = []
    t0 = time.time()

    def make(t: dict):
        @tool(t["name"], t["description"], t["inputSchema"])
        async def _run(args: dict) -> dict:
            steps.append({"type": "tool_call", "name": t["name"], "args": args, "ms": int((time.time() - t0) * 1000)})
            return {"content": [{"type": "text", "text": json.dumps(handle(t["name"], args), ensure_ascii=False)}]}

        return _run

    app = create_sdk_mcp_server(name="app", version="0", tools=[make(t) for t in TOOLS])
    env = {"ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": "mock"} if url else {}
    options = ClaudeAgentOptions(
        cwd=tempfile.mkdtemp(prefix="llm-api-probe-"),
        env=env,
        system_prompt=SYSTEM_PROMPT,
        tools=[],
        mcp_servers={"app": app},
        strict_mcp_config=True,
        setting_sources=[],
        allowed_tools=[f"mcp__app__{t['name']}" for t in TOOLS],
        permission_mode="bypassPermissions",
        max_turns=10,
        # No `persist_session` / `title` in the Python SDK: pass the CLI flags.
        # --name also stops Claude Code from sending the prompt again to name the session.
        extra_args={"no-session-persistence": None, "name": "llm-api-probe"},
    )
    model = None
    error = None
    usage = None
    try:
        async for m in query(prompt=PROMPT, options=options):
            kind = type(m).__name__
            if kind == "SystemMessage" and getattr(m, "subtype", "") == "init":
                model = m.data.get("model")
            elif kind == "AssistantMessage":
                for c in m.content:
                    if type(c).__name__ == "TextBlock" and c.text.strip():
                        steps.append({"type": "message", "text": c.text, "ms": int((time.time() - t0) * 1000)})
            elif kind == "ResultMessage":
                usage = {"usage": m.usage, "total_cost_usd": m.total_cost_usd, "num_turns": m.num_turns}
                if m.is_error:
                    error = {"subtype": m.subtype, "result": m.result}
    except Exception as e:  # the capture server answers with an error
        error = error or str(e)[:2000]
    if server:
        server.shutdown()
    return {"runtime": "claude-py", "mock": mock, "model": model, "steps": steps, "usage": usage,
            "error": error, "totalMs": int((time.time() - t0) * 1000)}


def main() -> None:
    which = sys.argv[1]
    mock = "--mock" in sys.argv
    result = run_codex(mock) if which == "codex" else asyncio.run(run_claude(mock))
    out = RESULTS / f"{result['runtime']}{'-mock' if mock else ''}.json"
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {out}")
    print(json.dumps({"steps": len(result["steps"]), "error": result["error"]}, ensure_ascii=False)[:800])


if __name__ == "__main__":
    main()
