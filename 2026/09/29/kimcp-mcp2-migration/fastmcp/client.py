"""A LangChain-free kimcp client on fastmcp's client alone (fastmcp-slim[client] 4.0.10).

Uses `fastmcp.Client.call_tool_mcp`, which returns the MCP `CallToolResult`
as-is. Runs the same gateway cases as ../sdk/client.py.
"""

import argparse
import asyncio
import json
import os
import re
import time
from typing import Any

from fastmcp import Client
from fastmcp.client.transports import SSETransport, StdioTransport, StreamableHttpTransport


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


def transport(args, *, all_fields: bool = False, keep_alive: bool | None = None):
    """Build the transport. `all_fields` sets what fastmcp still accepts of kimcp 0.1.0's fields
    (stdio `encoding`, SSE `timeout` and HTTP `timeout`/`sse_read_timeout`/`terminate_on_close` have no argument)."""
    if args.transport == "stdio":
        if all_fields:
            return StdioTransport(command=args.command, args=args.args, env={"KIMCP_PROBE": "1"}, cwd=os.getcwd())
        return StdioTransport(command=args.command, args=args.args, keep_alive=keep_alive)
    if args.transport == "sse":
        if all_fields:
            return SSETransport(args.url, headers={"X-Kimcp-Probe": "1"}, sse_read_timeout=300)
        return SSETransport(args.url)
    if all_fields:
        return StreamableHttpTransport(args.url, headers={"X-Kimcp-Probe": "1"})
    return StreamableHttpTransport(args.url)


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


async def on_elicit(message, response_type, params, context):
    return {"name": "kiarina"}


async def in_task(coro):
    """Run `coro` in a fresh task, the way a new FastAPI request would."""
    return await asyncio.create_task(coro)


async def main(args) -> dict[str, Any]:
    out: dict[str, Any] = {"client": "fastmcp", "mode": args.mode}
    cases: dict[str, Any] = {}

    t0 = time.perf_counter()
    client = Client(transport(args), mode=args.mode)
    await client.__aenter__()
    out["connect_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    out["protocol_version"] = client.protocol_version
    out["server_info"] = short(dump(client.server_info))

    tools = {t.name: t for t in await client.list_tools()}
    out["tools"] = sorted(tools)
    out["open_object_schema"] = dump(tools["open_object"].input_schema)
    out["structured_output_schema"] = dump(tools["structured"].output_schema)

    def call(name, arguments):
        return client.call_tool_mcp(name, arguments)

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
    if args.transport == "stdio":
        out["stdio_child_alive_after_disconnect"] = alive(first_pid)
        await client.transport.close()
        await asyncio.sleep(0.5)
        out["stdio_child_alive_after_transport_close"] = alive(first_pid)
        async with Client(transport(args, keep_alive=False), mode=args.mode) as c:
            ka_pid = pid_of(await outcome(c.call_tool_mcp("pid", {})))
        await asyncio.sleep(0.5)
        out["stdio_child_alive_after_disconnect_keep_alive_false"] = alive(ka_pid)

    async with Client(transport(args, all_fields=True), mode=args.mode) as c:
        cases["connect_with_all_fields_add"] = await outcome(c.call_tool_mcp("add", {"a": 1, "b": 2}))

    c = Client(transport(args), mode=args.mode, timeout=1)
    await c.__aenter__()
    cases["timeout_1s_on_2s_tool"] = await outcome(c.call_tool_mcp("slow", {"seconds": 2}))
    cases["add_after_timeout"] = await outcome(c.call_tool_mcp("add", {"a": 2, "b": 3}))
    cases["disconnect_after_timeout"] = await outcome(c.__aexit__(None, None, None))

    async with Client(transport(args), mode=args.mode, elicitation_handler=on_elicit) as c:
        cases["elicit_with_handler"] = await outcome(c.call_tool_mcp("ask", {}))
        if "ask_modern" in tools:
            cases["elicit_modern_with_handler"] = await outcome(c.call_tool_mcp("ask_modern", {}))

    # kimcp's shape: connect, call and disconnect each in its own task.
    naive = Client(transport(args, keep_alive=False), mode=args.mode)
    cases["cross_task_connect"] = await outcome(in_task(naive.__aenter__()))
    if cases["cross_task_connect"]["ok"]:
        cases["cross_task_call"] = await outcome(in_task(naive.call_tool_mcp("pid", {})))
        cases["cross_task_disconnect"] = await outcome(in_task(naive.__aexit__(None, None, None)))
        await asyncio.sleep(0.5)
        if args.transport == "stdio":
            out["stdio_child_alive_after_cross_task_disconnect"] = alive(pid_of(cases["cross_task_call"]))

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
