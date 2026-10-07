"""Can a one-shot call stop at the model's first tool calls, before any tool runs?

A chat provider returns one model turn: the text and the tool calls. The caller
runs the tools. So the runtime must hand over the tool calls and stop, without
running them and without sending the model a second request.

The capture server answers the first model request with two tool calls
(get_team_members and check_availability) and any later request with a text
message. Nothing reaches the real API.

    uv run stop_probe.py codex [--answer] [--serial]
    uv run stop_probe.py claude [--answer]

--answer   let the tools return at once (to see the order of events)
--serial   leave supports_parallel_tool_calls off in Codex's model entry
"""

from __future__ import annotations

import os
import sys

for _k in list(os.environ):
    if _k == "CLAUDECODE" or _k.startswith(("CLAUDE_CODE_", "ANTHROPIC_")) or _k == "CLAUDE_AGENT_SDK_VERSION":
        del os.environ[_k]

import asyncio
import json
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from probe import FIXTURE, MODEL, RESULTS, SYSTEM_PROMPT, TOOLS, codex_overrides

LAB = Path(__file__).resolve().parent.parent
CALLS = [
    ("call_a", "get_team_members", {}),
    ("call_b", "check_availability", {"place_id": "plc_0417", "date": "2026-10-23", "time": "19:30", "party_size": 9}),
]

T0 = time.time()
TURNS = int(sys.argv[sys.argv.index("--turns") + 1]) if "--turns" in sys.argv else 10
timeline: list[dict] = []


def log(event: str, **kw: object) -> None:
    timeline.append({"ms": int((time.time() - T0) * 1000), "event": event, **kw})


# --- capture server that answers -------------------------------------------


def sse(events: list[tuple[str, dict]]) -> bytes:
    return "".join(f"event: {e}\ndata: {json.dumps(d)}\n\n" for e, d in events).encode()


def responses_body(n: int) -> bytes:
    usage = {"input_tokens": 100, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 10,
             "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 110}
    if n == 1:
        items = [{"type": "function_call", "id": f"fc_{c}", "call_id": c, "name": name, "arguments": json.dumps(args),
                  "status": "completed"} for c, name, args in CALLS]
    else:
        items = [{"type": "message", "id": "msg_1", "role": "assistant", "status": "completed",
                  "content": [{"type": "output_text", "text": "done", "annotations": []}]}]
    ev: list[tuple[str, dict]] = [("response.created", {"type": "response.created", "response": {"id": f"resp_{n}"}})]
    for i, it in enumerate(items):
        ev.append(("response.output_item.added", {"type": "response.output_item.added", "output_index": i, "item": it}))
        ev.append(("response.output_item.done", {"type": "response.output_item.done", "output_index": i, "item": it}))
    ev.append(("response.completed", {"type": "response.completed",
                                      "response": {"id": f"resp_{n}", "output": items, "usage": usage}}))
    return sse(ev)


def messages_body(n: int) -> bytes:
    msg = {"id": f"msg_{n}", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [],
           "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 100, "output_tokens": 1}}
    ev: list[tuple[str, dict]] = [("message_start", {"type": "message_start", "message": msg})]
    if n == 1:
        for i, (c, name, args) in enumerate(CALLS):
            ev.append(("content_block_start", {"type": "content_block_start", "index": i, "content_block":
                                               {"type": "tool_use", "id": f"toolu_{c}", "name": f"mcp__app__{name}", "input": {}}}))
            ev.append(("content_block_delta", {"type": "content_block_delta", "index": i,
                                               "delta": {"type": "input_json_delta", "partial_json": json.dumps(args)}}))
            ev.append(("content_block_stop", {"type": "content_block_stop", "index": i}))
        stop = "tool_use"
    else:
        ev.append(("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}))
        ev.append(("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "done"}}))
        ev.append(("content_block_stop", {"type": "content_block_stop", "index": 0}))
        stop = "end_turn"
    ev.append(("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                 "usage": {"output_tokens": 10}}))
    ev.append(("message_stop", {"type": "message_stop"}))
    return sse(ev)


def start_server() -> tuple[str, ThreadingHTTPServer, list[dict]]:
    model_requests: list[dict] = []

    class H(BaseHTTPRequestHandler):
        def _handle(self) -> None:
            n = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(n).decode() if n else ""
            path = self.path.split("?")[0]
            if self.command == "POST" and path in ("/v1/responses", "/v1/messages"):
                body = json.loads(raw)
                model_requests.append(body)
                k = len(model_requests)
                log("model_request", n=k, parallel_tool_calls=body.get("parallel_tool_calls"))
                out = responses_body(k) if path == "/v1/responses" else messages_body(k)
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                self.wfile.write(out)
                return
            self.send_response(404 if self.command != "HEAD" else 200)
            self.end_headers()

        do_POST = do_GET = do_HEAD = _handle

        def log_message(self, *_: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}", server, model_requests


# --- codex ------------------------------------------------------------------


def run_codex(answer: bool, serial: bool) -> dict:
    from openai_codex import CodexConfig
    from openai_codex.client import CodexClient

    url, server, model_requests = start_server()
    calls: list[dict] = []
    first_call = threading.Event()
    release = threading.Event()

    overrides = list(codex_overrides())
    if not serial:
        # Same catalog as probe.py, plus supports_parallel_tool_calls.
        i = next(i for i, o in enumerate(overrides) if o.startswith("model_catalog_json="))
        path = Path(overrides[i].split("=", 1)[1].strip('"'))
        catalog = json.loads(path.read_text())
        catalog["models"][0]["supports_parallel_tool_calls"] = True
        path.write_text(json.dumps(catalog))

    def on_request(method: str, params: dict | None) -> dict:
        log("server_request", method=method, tool=(params or {}).get("tool"), callId=(params or {}).get("callId"))
        if method == "item/tool/call" and params:
            calls.append(params)
            first_call.set()
            if not answer:
                # Hold the reply: Codex cannot go on without it.
                release.wait(timeout=30)
            return {"contentItems": [{"type": "inputText", "text": "{}"}], "success": True}
        return {}

    class HoldingClient(CodexClient):
        """Reads on while tool calls wait for a reply (the SDK's reader replies inline)."""

        def _reader_loop(self) -> None:
            try:
                while True:
                    msg = self._read_message()
                    if "method" in msg and "id" in msg:
                        if msg["method"] == "item/tool/call" and not answer:
                            p = msg.get("params") or {}
                            log("server_request", method=msg["method"], tool=p.get("tool"), callId=p.get("callId"), held=True)
                            calls.append(p)
                            first_call.set()
                            continue
                        self._write_message({"id": msg["id"], "result": self._handle_server_request(msg)})
                        continue
                    if "method" in msg:
                        if not answer:
                            p = msg.get("params") or {}
                            it = p.get("item") or {}
                            log("notification", method=msg["method"], item_type=it.get("type"),
                                name=it.get("name"), call_id=it.get("call_id") or it.get("callId"),
                                keys=sorted(p)[:8] if msg["method"].startswith("raw") else None)
                        self._router.route_notification(self._coerce_notification(msg["method"], msg.get("params")))
                        continue
                    self._router.route_response(msg)
            except BaseException as exc:
                self._router.fail_all(exc)

    client = HoldingClient(
        config=CodexConfig(config_overrides=tuple(overrides), client_name="llm-api-stop-probe"),
        approval_handler=on_request,
    )
    client.start()
    client.initialize()
    started = client.thread_start({
        "cwd": tempfile.mkdtemp(prefix="llm-api-stop-"), "ephemeral": True, "approvalPolicy": "never",
        "sandbox": "read-only", "baseInstructions": SYSTEM_PROMPT, "model": MODEL,
        "dynamicTools": [{"type": "function", **t} for t in TOOLS],
        "config": {"model_providers": {"mock": {"name": "mock", "base_url": f"{url}/v1", "wire_api": "responses"}}},
        "modelProvider": "mock",
        "experimentalRawEvents": True,
    })
    turn = client.turn_start(started.thread.id, "test")
    turn_id = turn.turn.id
    client.register_turn_notifications(turn_id)
    if answer:
        while True:
            n = client.next_turn_notification(turn_id)
            p = n.payload.model_dump(mode="json", by_alias=True) if hasattr(n.payload, "model_dump") else {}
            item = p.get("item") or {}
            log("notification", method=n.method, item_type=item.get("type"), tool=item.get("tool"))
            if n.method == "turn/completed":
                break
    else:
        first_call.wait(timeout=30)
        time.sleep(1.0)  # give a parallel call time to show up (it cannot while the reader is held)
        log("closing")
        t = time.time()
        client.close()
        release.set()
        time.sleep(1.0)  # would a late request still go out?
        log("closed", close_ms=int((time.time() - t) * 1000))
    time.sleep(0.5)
    server.shutdown()
    return {"runtime": "codex", "answer": answer, "serial": serial, "model_requests": len(model_requests),
            "tool_calls": [{"tool": c.get("tool"), "callId": c.get("callId"), "arguments": c.get("arguments")} for c in calls],
            "timeline": timeline}


# --- claude -----------------------------------------------------------------


async def run_claude(answer: bool) -> dict:
    from claude_agent_sdk import ClaudeAgentOptions, create_sdk_mcp_server, query, tool

    url, server, model_requests = start_server()
    handled: list[str] = []
    seen_tool_use: list[dict] = []

    def make(t: dict):
        @tool(t["name"], t["description"], t["inputSchema"])
        async def _run(args: dict) -> dict:
            log("tool_handler", tool=t["name"])
            handled.append(t["name"])
            if not answer:
                await asyncio.Event().wait()  # never runs: the caller runs the tools
            return {"content": [{"type": "text", "text": "{}"}]}

        return _run

    app = create_sdk_mcp_server(name="app", version="0", tools=[make(t) for t in TOOLS])
    options = ClaudeAgentOptions(
        cwd=tempfile.mkdtemp(prefix="llm-api-stop-"),
        env={"ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": "mock"},
        system_prompt=SYSTEM_PROMPT, tools=[], mcp_servers={"app": app}, strict_mcp_config=True, setting_sources=[],
        allowed_tools=[f"mcp__app__{t['name']}" for t in TOOLS], permission_mode="bypassPermissions", max_turns=TURNS,
        extra_args={"no-session-persistence": None, "name": "llm-api-stop-probe"},
        include_partial_messages=True,
    )
    gen = query(prompt="test", options=options)
    try:
        async for m in gen:
            kind = type(m).__name__
            blocks = [type(c).__name__ for c in getattr(m, "content", []) or []] if kind == "AssistantMessage" else None
            if kind == "StreamEvent":
                ev = m.event
                log("stream", type=ev.get("type"), block=(ev.get("content_block") or {}).get("type"),
                    stop_reason=(ev.get("delta") or {}).get("stop_reason"))
                # The end of the model turn: every tool_use block has arrived.
                if ev.get("type") == "message_stop" and not answer:
                    log("closing")
                    break
                continue
            log("message", kind=kind, blocks=blocks, stop_reason=getattr(m, "stop_reason", None),
                subtype=getattr(m, "subtype", None))
            if kind == "AssistantMessage":
                seen_tool_use.extend({"id": c.id, "name": c.name, "input": c.input}
                                     for c in m.content if type(c).__name__ == "ToolUseBlock")
    except Exception as e:  # max_turns ends with an error result
        log("error", type=type(e).__name__, text=str(e)[:200])
    finally:
        t = time.time()
        await gen.aclose()
        log("closed", close_ms=int((time.time() - t) * 1000))
    await asyncio.sleep(1.0)  # would a late request still go out?
    server.shutdown()
    return {"runtime": "claude", "answer": answer, "model_requests": len(model_requests), "tool_use": seen_tool_use,
            "handlers_called": handled, "timeline": timeline}


def main() -> None:
    which = sys.argv[1]
    answer = "--answer" in sys.argv
    if which == "codex":
        result = run_codex(answer, "--serial" in sys.argv)
    else:
        result = asyncio.run(run_claude(answer))
    tag = "-answer" if answer else "-stop"
    tag += "-serial" if result.get("serial") else ""
    tag += f"-turns{TURNS}" if "--turns" in sys.argv else ""
    out = RESULTS / f"stop-{which}{tag}.json"
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=1)[:3000])


if __name__ == "__main__":
    main()
