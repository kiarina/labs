"""The client a migrated kimcp would use: langchain.mcp on fastmcp 4 / mcp 2.2.

kimcp keeps one live session per registered server, so the candidate design
builds a `fastmcp.Client` from kimcp's own connection model, enters it once on
connect, and wraps each tool with `as_langchain_tool`. `MCPAdapter` is probed
separately for the cases where its defaults differ.
"""

import argparse
import asyncio
import json
import os
import re
import time
import warnings
from typing import Any

from langchain_core._api import LangChainBetaWarning

warnings.filterwarnings("ignore", category=LangChainBetaWarning)

from fastmcp import Client  # noqa: E402
from fastmcp.client.transports import SSETransport, StdioTransport, StreamableHttpTransport  # noqa: E402
from langchain.mcp import MCPAdapter, as_langchain_tool  # noqa: E402


def short(value: Any, limit: int = 300) -> str:
    text = repr(value)
    return text if len(text) <= limit else text[:limit] + "..."


async def outcome(coro) -> dict[str, Any]:
    start = time.perf_counter()
    try:
        value = await coro
        return {"ok": True, "type": type(value).__name__, "value": short(value),
                "ms": round((time.perf_counter() - start) * 1000, 1)}
    except BaseException as exc:  # noqa: BLE001 - record everything
        return {"ok": False, "error": f"{type(exc).__module__}.{type(exc).__name__}",
                "message": short(str(exc)), "ms": round((time.perf_counter() - start) * 1000, 1)}


def transport(args):
    if args.transport == "stdio":
        return StdioTransport(command=args.command, args=args.args)
    if args.transport == "sse":
        return SSETransport(args.url)
    return StreamableHttpTransport(args.url)


def pid_of(case: dict[str, Any]) -> int | None:
    match = re.search(r"\d{2,}", case.get("value", "")) if case.get("ok") else None
    return int(match.group()) if match else None


def alive(pid: int | None) -> bool | None:
    if pid is None:
        return None
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


async def tools_of(client) -> dict[str, Any]:
    return {t.name: await as_langchain_tool(t, client) for t in await client.list_tools()}


async def main(args) -> dict[str, Any]:
    out: dict[str, Any] = {"client": "v2", "mode": args.mode}

    t0 = time.perf_counter()
    client = Client(transport(args), mode=args.mode)
    await client.__aenter__()
    out["connect_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    out["protocol_version"] = client.protocol_version
    out["server_info"] = short(client.server_info)

    tools = await tools_of(client)
    out["tools"] = sorted(tools)
    out["open_object_schema"] = tools["open_object"].args_schema
    out["tool_metadata"] = short(tools["add"].metadata)

    cases: dict[str, Any] = {}
    cases["add"] = await outcome(tools["add"].ainvoke({"a": 1, "b": 2}))
    cases["pid_1"] = await outcome(tools["pid"].ainvoke({}))
    cases["pid_2"] = await outcome(tools["pid"].ainvoke({}))
    cases["image"] = await outcome(tools["image"].ainvoke({}))
    cases["structured"] = await outcome(tools["structured"].ainvoke({}))
    cases["structured_toolcall"] = await outcome(tools["structured"].ainvoke(
        {"type": "tool_call", "id": "1", "name": "structured", "args": {}}))
    cases["fail"] = await outcome(tools["fail"].ainvoke({}))
    cases["open_object"] = await outcome(tools["open_object"].ainvoke({"options": {"x": 1, "y": 2}}))
    cases["elicit_no_handler"] = await outcome(tools["ask"].ainvoke({}))
    cases["list_resources"] = await outcome(client.list_resources())
    cases["list_prompts"] = await outcome(client.list_prompts())
    first_pid = pid_of(cases["pid_1"])
    cases["disconnect"] = await outcome(client.__aexit__(None, None, None))
    await asyncio.sleep(0.5)
    if args.transport == "stdio":
        # keep_alive defaults to True: leaving the context keeps the subprocess.
        out["stdio_child_alive_after_aexit"] = alive(first_pid)
        await client.transport.close()
        await asyncio.sleep(0.5)
        out["stdio_child_alive_after_transport_close"] = alive(first_pid)

    # Per-request timeout, now a Client argument.
    c = Client(transport(args), mode=args.mode, timeout=1)
    await c.__aenter__()
    timeout_tools = await tools_of(c)
    cases["timeout_1s_on_2s_tool"] = await outcome(timeout_tools["slow"].ainvoke({"seconds": 2}))
    cases["add_after_timeout"] = await outcome(timeout_tools["add"].ainvoke({"a": 2, "b": 3}))
    cases["disconnect_after_timeout"] = await outcome(c.__aexit__(None, None, None))

    # Elicitation answered by a handler on the client (what kimcp could expose).
    async def on_elicit(message, response_type, params, context):
        return {"name": "kiarina"}

    async with Client(transport(args), mode=args.mode, elicitation_handler=on_elicit) as c:
        handler_tools = await tools_of(c)
        cases["elicit_with_handler"] = await outcome(handler_tools["ask"].ainvoke({}))
        if "ask_modern" in handler_tools:
            cases["elicit_modern_with_handler"] = await outcome(handler_tools["ask_modern"].ainvoke({}))
    if "ask_modern" in tools:
        async with Client(transport(args), mode=args.mode) as c:
            cases["elicit_modern_no_handler"] = await outcome((await tools_of(c))["ask_modern"].ainvoke({}))

    # MCPAdapter defaults: tools stay usable after its context exits, and
    # elicitation is armed as a LangGraph interrupt. Called here outside a graph.
    adapter = MCPAdapter(Client(transport(args), mode=args.mode))
    adapter_tools = {t.name: t for t in await adapter.list_tools()}
    cases["adapter_pid_1"] = await outcome(adapter_tools["pid"].ainvoke({}))
    cases["adapter_pid_2"] = await outcome(adapter_tools["pid"].ainvoke({}))
    cases["adapter_elicit_outside_graph"] = await outcome(adapter_tools["ask"].ainvoke({}))
    if "ask_modern" in adapter_tools:
        cases["adapter_elicit_modern_outside_graph"] = await outcome(adapter_tools["ask_modern"].ainvoke({}))

    out["cases"] = cases
    return out


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--transport", required=True, choices=["stdio", "sse", "streamable_http"])
    p.add_argument("--url")
    p.add_argument("--command")
    p.add_argument("--args", nargs="*", default=[])
    p.add_argument("--mode", default="auto", help="fastmcp connect mode: auto or legacy")
    a = p.parse_args()
    print(json.dumps(asyncio.run(main(a)), ensure_ascii=False, default=str))
