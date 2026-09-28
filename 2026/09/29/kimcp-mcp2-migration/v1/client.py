"""The client kimcp 0.1.0 uses today: langchain-mcp-adapters 0.3.2 on mcp 1.30.

Replays kimcp's flow (MultiServerMCPClient.session -> load_mcp_tools ->
tool.ainvoke) and prints one JSON object with each case's outcome.
"""

import argparse
import asyncio
import datetime
import json
import os
import re
import time
from typing import Any

from langchain_mcp_adapters.client import MultiServerMCPClient
from langchain_mcp_adapters.tools import load_mcp_tools
from mcp.types import ElicitResult


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


def child_alive(args, cases: dict[str, Any]) -> bool | None:
    """After disconnect, is the stdio server process from pid_1 still running?"""
    if args.transport != "stdio" or not cases["pid_1"]["ok"]:
        return None
    match = re.search(r"\d{2,}", cases["pid_1"]["value"])
    if match is None:
        return None
    time.sleep(0.5)
    try:
        os.kill(int(match.group()), 0)
        return True
    except ProcessLookupError:
        return False


def connection(args) -> dict[str, Any]:
    if args.transport == "stdio":
        return {"transport": "stdio", "command": args.command, "args": args.args}
    return {"transport": args.transport, "url": args.url}


async def open_session(conn: dict[str, Any], **client_kwargs):
    client = MultiServerMCPClient({"probe": conn}, **client_kwargs)
    cm = client.session("probe")
    session = await cm.__aenter__()
    return cm, session


async def main(args) -> dict[str, Any]:
    out: dict[str, Any] = {"client": "v1"}
    conn = connection(args)

    t0 = time.perf_counter()
    cm, session = await open_session(conn)
    out["connect_ms"] = round((time.perf_counter() - t0) * 1000, 1)

    tools = {t.name: t for t in await load_mcp_tools(session)}
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
    cases["disconnect"] = await outcome(cm.__aexit__(None, None, None))

    # Per-request timeout: kimcp passes it through session_kwargs today.
    cm, session = await open_session(
        {**conn, "session_kwargs": {"read_timeout_seconds": datetime.timedelta(seconds=1)}})
    slow = {t.name: t for t in await load_mcp_tools(session)}["slow"]
    cases["timeout_1s_on_2s_tool"] = await outcome(slow.ainvoke({"seconds": 2}))
    add = {t.name: t for t in await load_mcp_tools(session)}["add"]
    cases["add_after_timeout"] = await outcome(add.ainvoke({"a": 2, "b": 3}))
    cases["disconnect_after_timeout"] = await outcome(cm.__aexit__(None, None, None))

    # Elicitation with a handler (kimcp has none today; this shows it is possible).
    from langchain_mcp_adapters.callbacks import Callbacks

    async def on_elicitation(mcp_context, params, context):
        return ElicitResult(action="accept", content={"name": "kiarina"})

    cm, session = await open_session(conn, callbacks=Callbacks(on_elicitation=on_elicitation))
    ask = {t.name: t for t in await load_mcp_tools(session)}["ask"]
    cases["elicit_with_handler"] = await outcome(ask.ainvoke({}))
    await outcome(cm.__aexit__(None, None, None))

    # kimcp's shape: connect, call and disconnect each in its own task (each FastAPI request).
    async def in_task(coro):
        return await asyncio.create_task(coro)

    naive = MultiServerMCPClient({"probe": conn}).session("probe")
    naive_session: list[Any] = []

    async def naive_connect():
        naive_session.append(await naive.__aenter__())

    async def naive_call():
        pid_tool = {t.name: t for t in await load_mcp_tools(naive_session[0])}["pid"]
        return await pid_tool.ainvoke({})

    cases["cross_task_connect"] = await outcome(in_task(naive_connect()))
    if cases["cross_task_connect"]["ok"]:
        cases["cross_task_call"] = await outcome(in_task(naive_call()))
        cases["cross_task_disconnect"] = await outcome(in_task(naive.__aexit__(None, None, None)))

    out["cases"] = cases
    out["stdio_child_alive_after_disconnect"] = child_alive(args, cases)
    return out


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--transport", required=True, choices=["stdio", "sse", "streamable_http"])
    p.add_argument("--url")
    p.add_argument("--command")
    p.add_argument("--args", nargs="*", default=[])
    a = p.parse_args()
    print(json.dumps(asyncio.run(main(a)), ensure_ascii=False, default=str))
