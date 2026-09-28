"""A LangChain-free kimcp client on the MCP Python SDK alone (mcp 2.2).

Uses `mcp.Client` and returns MCP results as-is. Besides the cases the other
clients run, this probes what a gateway needs: calls from other asyncio tasks
(kimcp's FastAPI handlers each run in their own task), concurrent calls on one
session, and whether kimcp's existing connection fields still map.
"""

import argparse
import asyncio
import json
import os
import re
import time
from typing import Any

import httpx2
from mcp import Client
from mcp.client.sse import sse_client
from mcp.client.stdio import StdioServerParameters
from mcp.client.streamable_http import streamable_http_client
from mcp.types import ElicitResult


def short(value: Any, limit: int = 400) -> str:
    text = value if isinstance(value, str) else repr(value)
    return text if len(text) <= limit else text[:limit] + "..."


def dump(value: Any) -> Any:
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json", by_alias=True, exclude_none=True)
    if isinstance(value, list):
        return [dump(v) for v in value]
    return value


async def outcome(coro) -> dict[str, Any]:
    start = time.perf_counter()
    try:
        value = await coro
        return {"ok": True, "type": type(value).__name__, "value": short(json.dumps(dump(value), default=str)),
                "ms": round((time.perf_counter() - start) * 1000, 1)}
    except BaseException as exc:  # noqa: BLE001 - record everything
        return {"ok": False, "error": f"{type(exc).__module__}.{type(exc).__name__}",
                "message": short(str(exc)), "ms": round((time.perf_counter() - start) * 1000, 1)}


def server(args, *, all_fields: bool = False):
    """Build the connection target. `all_fields` sets every field kimcp 0.1.0 exposes."""
    if args.transport == "stdio":
        if all_fields:
            return StdioServerParameters(command=args.command, args=args.args, env={"KIMCP_PROBE": "1"},
                                         cwd=os.getcwd(), encoding="utf-8")
        return StdioServerParameters(command=args.command, args=args.args)
    if args.transport == "sse":
        if all_fields:
            return sse_client(args.url, headers={"X-Kimcp-Probe": "1"}, timeout=5, sse_read_timeout=300)
        return sse_client(args.url)
    if all_fields:
        http = httpx2.AsyncClient(headers={"X-Kimcp-Probe": "1"}, timeout=httpx2.Timeout(30, read=300))
        return streamable_http_client(args.url, http_client=http, terminate_on_close=True)
    return args.url


def pid_of(case: dict[str, Any]) -> int | None:
    match = re.search(r'"text": "(\d+)"', case.get("value", "")) if case.get("ok") else None
    return int(match.group(1)) if match else None


def alive(pid: int | None) -> bool | None:
    if pid is None:
        return None
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


async def on_elicit(context, params):
    return ElicitResult(action="accept", content={"name": "kiarina"})


class OwnedSession:
    """Keep one `mcp.Client` open inside a dedicated task.

    anyio cancel scopes must be exited by the task that entered them, and a
    gateway connects, calls and disconnects from different request tasks. The
    owner task enters the client, parks until `close()`, then exits it.
    """

    def __init__(self, target, **kwargs: Any) -> None:
        self._target = target
        self._kwargs = kwargs
        self._ready = asyncio.Event()
        self._stop = asyncio.Event()
        self._task: asyncio.Task | None = None
        self.client: Client | None = None
        self.error: BaseException | None = None

    async def open(self) -> "OwnedSession":
        self._task = asyncio.create_task(self._run())
        await self._ready.wait()
        if self.error:
            raise self.error
        return self

    async def _run(self) -> None:
        try:
            async with Client(self._target, **self._kwargs) as client:
                self.client = client
                self._ready.set()
                await self._stop.wait()
        except BaseException as exc:  # noqa: BLE001
            self.error = exc
            self._ready.set()
            raise

    async def close(self) -> None:
        self._stop.set()
        assert self._task is not None
        await self._task


async def in_task(coro):
    """Run `coro` in a fresh task, the way a new FastAPI request would."""
    return await asyncio.create_task(coro)


async def main(args) -> dict[str, Any]:
    out: dict[str, Any] = {"client": "sdk", "mode": args.mode}
    cases: dict[str, Any] = {}

    t0 = time.perf_counter()
    client = Client(server(args), mode=args.mode)
    await client.__aenter__()
    out["connect_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    out["protocol_version"] = client.protocol_version
    out["server_info"] = short(dump(client.server_info))

    tools = {t.name: t for t in (await client.list_tools()).tools}
    out["tools"] = sorted(tools)
    out["open_object_schema"] = dump(tools["open_object"].input_schema)
    out["structured_output_schema"] = dump(tools["structured"].output_schema)

    call = client.call_tool
    cases["add"] = await outcome(call("add", {"a": 1, "b": 2}))
    cases["pid_1"] = await outcome(call("pid", {}))
    cases["pid_2"] = await outcome(call("pid", {}))
    cases["image"] = await outcome(call("image", {}))
    cases["structured"] = await outcome(call("structured", {}))
    cases["fail"] = await outcome(call("fail", {}))
    cases["open_object"] = await outcome(call("open_object", {"options": {"x": 1, "y": 2}}))
    cases["elicit_no_handler"] = await outcome(call("ask", {}))
    if "ask_modern" in tools:
        cases["elicit_modern_no_handler"] = await outcome(call("ask_modern", {}))
    cases["list_resources"] = await outcome(client.list_resources())
    cases["list_prompts"] = await outcome(client.list_prompts())
    t = time.perf_counter()
    cases["concurrent_5x_slow_0_5s"] = await outcome(asyncio.gather(*[call("slow", {"seconds": 0.5}) for _ in range(5)]))
    cases["concurrent_5x_slow_0_5s"]["wall_ms"] = round((time.perf_counter() - t) * 1000, 1)
    first_pid = pid_of(cases["pid_1"])
    cases["disconnect"] = await outcome(client.__aexit__(None, None, None))
    await asyncio.sleep(0.5)
    out["stdio_child_alive_after_disconnect"] = alive(first_pid) if args.transport == "stdio" else None

    # Every connection field kimcp 0.1.0 exposes.
    async with Client(server(args, all_fields=True), mode=args.mode) as c:
        cases["connect_with_all_fields_add"] = await outcome(c.call_tool("add", {"a": 1, "b": 2}))

    # Request timeout, then recovery on the same session.
    c = Client(server(args), mode=args.mode, read_timeout_seconds=1)
    await c.__aenter__()
    cases["timeout_1s_on_2s_tool"] = await outcome(c.call_tool("slow", {"seconds": 2}))
    cases["add_after_timeout"] = await outcome(c.call_tool("add", {"a": 2, "b": 3}))
    cases["disconnect_after_timeout"] = await outcome(c.__aexit__(None, None, None))

    # Elicitation answered by a client callback.
    async with Client(server(args), mode=args.mode, elicitation_callback=on_elicit) as c:
        cases["elicit_with_handler"] = await outcome(c.call_tool("ask", {}))
        if "ask_modern" in tools:
            cases["elicit_modern_with_handler"] = await outcome(c.call_tool("ask_modern", {}))

    # kimcp's shape, naively: connect, call and disconnect each in its own task.
    naive = Client(server(args), mode=args.mode)
    cases["cross_task_connect"] = await outcome(in_task(naive.__aenter__()))
    if cases["cross_task_connect"]["ok"]:
        cases["cross_task_call"] = await outcome(in_task(naive.call_tool("pid", {})))
        cases["cross_task_disconnect"] = await outcome(in_task(naive.__aexit__(None, None, None)))
        await asyncio.sleep(0.5)
        if args.transport == "stdio":
            out["stdio_child_alive_after_cross_task_disconnect"] = alive(pid_of(cases["cross_task_call"]))

    # The same, with a task that owns the session.
    owned = OwnedSession(server(args), mode=args.mode)
    cases["owned_connect"] = await outcome(in_task(owned.open()))
    if cases["owned_connect"]["ok"]:
        cases["owned_call"] = await outcome(in_task(owned.client.call_tool("pid", {})))
        cases["owned_disconnect"] = await outcome(in_task(owned.close()))
        await asyncio.sleep(0.5)
        if args.transport == "stdio":
            out["stdio_child_alive_after_owned_disconnect"] = alive(pid_of(cases["owned_call"]))

    out["cases"] = cases
    return out


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--transport", required=True, choices=["stdio", "sse", "streamable_http"])
    p.add_argument("--url")
    p.add_argument("--command")
    p.add_argument("--args", nargs="*", default=[])
    p.add_argument("--mode", default="auto", help="connect mode: auto or legacy")
    a = p.parse_args()
    print(json.dumps(asyncio.run(main(a)), ensure_ascii=False, default=str))
