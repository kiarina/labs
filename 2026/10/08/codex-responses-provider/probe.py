"""Point codex app-server at a scripted Responses API server and record what it sends.

    uv run probe.py tuned   # one process tuned for a local model, a tool round trip (no tokens)
    uv run probe.py mixed   # one default process, an OpenAI thread and a scripted thread at once
                            # (the OpenAI thread sends one tiny request on the subscription)

The scripted server answers like the Responses API: the first request of a turn gets a
call to the shell tool, the request carrying its output gets a final message. Raw requests
go to results/*-requests.json (gitignored); the summaries to results/*.json.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from openai_codex import CodexConfig
from openai_codex.client import CodexClient

LAB = Path(__file__).resolve().parent
RESULTS = LAB / "results"
CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
LOCAL_MODEL = "kiapi-local"  # a slug OpenAI does not know; only our catalog has it
OPENAI_MODEL = "gpt-5.6-luna"  # the cheapest listed model, for the one real request
SHELL_COMMAND = "echo hello-from-tool"
FINAL_TEXT = "SCRIPTED-DONE"


# --- scripted Responses server ----------------------------------------------


class Scripted:
    def __init__(self, name: str) -> None:
        self.name = name
        self.requests: list[dict] = []
        self.lock = threading.Lock()
        self.seq = 0

    def next_id(self, prefix: str) -> str:
        with self.lock:
            self.seq += 1
            return f"{prefix}_{self.seq}"

    def record(self, entry: dict) -> None:
        with self.lock:
            self.requests.append(entry)
            (RESULTS / f"{self.name}-requests.json").write_text(json.dumps(self.requests, ensure_ascii=False, indent=2))

    def reply(self, body: dict) -> list[dict]:
        """The output items for one request."""
        items = body.get("input") or []
        last = items[-1] if items else {}
        if last.get("type") in ("function_call_output", "custom_tool_call_output"):
            return [self._message(f"{FINAL_TEXT} (saw: {str(last.get('output'))[:200]})")]
        call = self._shell_call(body.get("tools") or [])
        return [call] if call else [self._message(FINAL_TEXT)]

    def _message(self, text: str) -> dict:
        return {"type": "message", "id": self.next_id("msg"), "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": text, "annotations": []}]}

    def _shell_call(self, tools: list[dict]) -> dict | None:
        names = {t.get("name"): t for t in tools if t.get("type") == "function"}
        if "exec_command" in names:
            args = {"cmd": SHELL_COMMAND}
        elif "shell_command" in names:
            args = {"command": SHELL_COMMAND}
        elif "shell" in names:
            args = {"command": ["bash", "-lc", SHELL_COMMAND]}
        else:
            return None
        name = next(n for n in ("exec_command", "shell_command", "shell") if n in names)
        return {"type": "function_call", "id": self.next_id("fc"), "call_id": self.next_id("call"), "name": name,
                "arguments": json.dumps(args), "status": "completed"}


def sse(events: list[dict]) -> bytes:
    return b"".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n".encode() for e in events)


def stream_events(resp_id: str, output: list[dict], model: str) -> list[dict]:
    base = {"id": resp_id, "object": "response", "created_at": int(time.time()), "model": model}
    events: list[dict] = [{"type": "response.created", "response": {**base, "status": "in_progress", "output": []}}]
    for i, item in enumerate(output):
        events.append({"type": "response.output_item.added", "output_index": i, "item": {**item, "status": "in_progress"}})
        if item["type"] == "message":
            text = item["content"][0]["text"]
            events.append({"type": "response.output_text.delta", "item_id": item["id"], "output_index": i,
                           "content_index": 0, "delta": text})
        events.append({"type": "response.output_item.done", "output_index": i, "item": item})
    usage = {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 5,
             "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 15}
    events.append({"type": "response.completed", "response": {**base, "status": "completed", "output": output, "usage": usage}})
    return events


def start_server(script: Scripted) -> tuple[str, ThreadingHTTPServer]:
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _handle(self) -> None:
            n = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(n).decode() if n else ""
            try:
                body: object = json.loads(raw) if raw else None
            except ValueError:
                body = raw
            headers = {k.lower(): ("<redacted, present>" if k.lower() in ("authorization", "chatgpt-account-id") else v)
                       for k, v in self.headers.items()}
            script.record({"t": time.time(), "method": self.command, "path": self.path, "headers": headers, "body": body})
            if self.command == "POST" and self.path.rstrip("/").endswith("/responses") and isinstance(body, dict):
                data = sse(stream_events(script.next_id("resp"), script.reply(body), body.get("model", "")))
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(404)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

        do_POST = do_GET = _handle

        def log_message(self, *_: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/v1", server


# --- codex --------------------------------------------------------------------


def local_catalog() -> Path:
    """A catalog entry for a model OpenAI does not serve, without code mode."""
    cache = json.loads((CODEX_HOME / "models_cache.json").read_text())
    base = next(m for m in cache["models"] if m["slug"] == OPENAI_MODEL)
    entry = {**base, "slug": LOCAL_MODEL, "display_name": LOCAL_MODEL, "description": "kiapi local model",
             "tool_mode": None, "multi_agent_version": None, "apply_patch_tool_type": None,
             "use_responses_lite": False, "supports_search_tool": False, "experimental_supported_tools": [],
             "include_skills_usage_instructions": False,
             "include_apps_usage_instructions": False, "include_plugin_usage_instructions": False,
             "node_repl_disabled": True, "service_tiers": [], "additional_speed_tiers": []}
    path = Path(tempfile.mkdtemp(prefix="codex-local-catalog-")) / "models.json"
    path.write_text(json.dumps({"models": [entry]}))
    return path


def tuned_overrides(url: str) -> tuple[str, ...]:
    """Process-level settings for the local-model process (thread/start's config does not reach these)."""
    o = [
        f'model_providers.kiapi={{name="kiapi", base_url="{url}", wire_api="responses"}}',
        'model_provider="kiapi"',
        f'model="{LOCAL_MODEL}"',
        f'model_catalog_json="{local_catalog()}"',
        'web_search="disabled"',
    ]
    for f in ["code_mode_host", "multi_agent", "apps", "plugins", "image_generation", "computer_use", "browser_use",
              "browser_use_external", "in_app_browser", "goals", "tool_suggest", "skill_search", "memories"]:
        o.append(f"features.{f}=false")
    return tuple(o)


def run_turn(client: CodexClient, thread_id: str, prompt: str, log: list[dict], t0: float) -> dict:
    turn = client.turn_start(thread_id, prompt)
    turn_id = turn.turn.id
    client.register_turn_notifications(turn_id)
    result: dict = {"thread": thread_id, "items": [], "error": None}
    try:
        while True:
            n = client.next_turn_notification(turn_id)
            p = n.payload.model_dump(mode="json", by_alias=True) if hasattr(n.payload, "model_dump") else {}
            if n.method == "item/completed":
                item = p.get("item", {})
                kept = {k: item.get(k) for k in ("type", "text", "command", "aggregatedOutput", "exitCode", "status") if item.get(k) is not None}
                result["items"].append({**kept, "ms": int((time.time() - t0) * 1000)})
            elif n.method in ("error", "turn/completed"):
                if n.method == "turn/completed":
                    result["error"] = p.get("turn", {}).get("error")
                    result["status"] = p.get("turn", {}).get("status")
                    break
                result["error"] = p
    finally:
        client.unregister_turn_notifications(turn_id)
    result["ms"] = int((time.time() - t0) * 1000)
    log.append(result)
    return result


REDACT = ("x-codex-turn-metadata", "client_metadata", "x-codex-installation-id")


def redact(d: dict) -> dict:
    """Keep the shape, not the ids (installation id, thread ids, local paths)."""
    return {k: (sorted(json.loads(v)) if k == "x-codex-turn-metadata" else sorted(v) if isinstance(v, dict) else "<redacted>")
            if k in REDACT else v for k, v in d.items()}


def summarize(script: Scripted) -> list[dict]:
    out = []
    for r in script.requests:
        b = r["body"] if isinstance(r["body"], dict) else {}
        out.append({
            "method": r["method"], "path": r["path"],
            "headers": redact({k: v for k, v in r["headers"].items() if k not in ("content-length", "host")}),
            "keys": sorted(b),
            "params": redact({k: b[k] for k in sorted(b) if k not in ("input", "tools", "instructions")}),
            "instructions_chars": len(b.get("instructions") or ""),
            "tools": [{"type": t.get("type"), "name": t.get("name"), "params": sorted((t.get("parameters") or {}).get("properties", {}))}
                      for t in b.get("tools") or []],
            "input": [{"type": i.get("type"), "role": i.get("role"),
                       "content_types": [c.get("type") for c in i.get("content", [])] if isinstance(i.get("content"), list) else None,
                       "chars": len(json.dumps(i, ensure_ascii=False))}
                      for i in b.get("input") or []],
        })
    return out


def tuned() -> dict:
    script = Scripted("tuned")
    url, server = start_server(script)
    t0 = time.time()
    cwd = tempfile.mkdtemp(prefix="codex-local-")
    # A home of its own: none of the user's MCP servers, skills or login. The provider needs no login.
    home = tempfile.mkdtemp(prefix="codex-local-home-")
    env = {**os.environ, "CODEX_HOME": home}
    client = CodexClient(config=CodexConfig(config_overrides=tuned_overrides(url), env=env, client_name="codex-responses-provider"))
    client.start()
    client.initialize()
    started = client.thread_start({"cwd": cwd, "ephemeral": True, "approvalPolicy": "never", "sandbox": "workspace-write"})
    turns: list[dict] = []
    run_turn(client, started.thread.id, f"Run `{SHELL_COMMAND}` in the shell and tell me what it printed.", turns, t0)
    run_turn(client, started.thread.id, "Thanks. One more word: done?", turns, t0)
    client.close()
    server.shutdown()
    return {"scenario": "tuned", "model": LOCAL_MODEL, "turns": turns, "requests": summarize(script)}


def mixed() -> dict:
    script = Scripted("mixed")
    url, server = start_server(script)
    t0 = time.time()
    client = CodexClient(config=CodexConfig(client_name="codex-responses-provider"))
    client.start()
    client.initialize()
    common = {"ephemeral": True, "approvalPolicy": "never", "sandbox": "read-only"}
    openai_thread = client.thread_start({**common, "cwd": tempfile.mkdtemp(prefix="codex-openai-"), "model": OPENAI_MODEL})
    scripted_thread = client.thread_start({
        **common, "cwd": tempfile.mkdtemp(prefix="codex-scripted-"), "model": OPENAI_MODEL,
        "config": {"model_providers": {"scripted": {"name": "scripted", "base_url": url, "wire_api": "responses"}}},
        "modelProvider": "scripted",
    })
    turns: list[dict] = []
    jobs = [
        threading.Thread(target=run_turn, args=(client, openai_thread.thread.id, "Reply with exactly: OK", turns, t0)),
        threading.Thread(target=run_turn, args=(client, scripted_thread.thread.id, "Reply with exactly: OK", turns, t0)),
    ]
    for j in jobs:
        j.start()
    for j in jobs:
        j.join(timeout=300)
    client.close()
    server.shutdown()
    for t in turns:
        t["provider"] = "openai" if t["thread"] == openai_thread.thread.id else "scripted"
    return {"scenario": "mixed", "model": OPENAI_MODEL, "turns": turns, "requests": summarize(script)}


def main() -> None:
    which = sys.argv[1]
    RESULTS.mkdir(exist_ok=True)
    result = tuned() if which == "tuned" else mixed()
    out = RESULTS / f"{which}.json"
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {out}")
    for t in result["turns"]:
        print(json.dumps({k: t.get(k) for k in ("provider", "status", "error", "ms")}, ensure_ascii=False),
              [(i.get("type"), (i.get("text") or i.get("command") or "")[:80]) for i in t["items"]])
    print("requests:", [(r["method"], r["path"]) for r in result["requests"]])


if __name__ == "__main__":
    main()
