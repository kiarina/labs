"""MCP 1 test server (mcp 1.30, `mcp.server.fastmcp.FastMCP`).

Same tools as ../v2/server.py so each client sees the same surface.
"""

import argparse
import asyncio
import base64
import os
from typing import Any

from mcp.server.fastmcp import Context, FastMCP, Image
from pydantic import BaseModel

PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)

mcp = FastMCP("probe-v1")


class Name(BaseModel):
    name: str


@mcp.tool()
def add(a: int, b: int) -> int:
    """Add two numbers"""
    return a + b


@mcp.tool()
def pid() -> int:
    """Return the server process id"""
    return os.getpid()


@mcp.tool()
def image() -> Image:
    """Return a 1x1 PNG"""
    return Image(data=PNG_1X1, format="png")


@mcp.tool()
def structured() -> dict[str, Any]:
    """Return structured content"""
    return {"answer": 42, "items": ["a", "b"]}


@mcp.tool()
def fail() -> str:
    """Raise inside the tool"""
    raise ValueError("boom from tool")


@mcp.tool()
def open_object(options: dict[str, Any]) -> str:
    """Take an open object argument"""
    return ",".join(sorted(options))


@mcp.tool()
async def slow(seconds: float) -> str:
    """Sleep then return"""
    await asyncio.sleep(seconds)
    return "done"


@mcp.tool()
async def ask(ctx: Context) -> str:
    """Ask the client for a name through elicitation"""
    result = await ctx.elicit("What is your name?", Name)
    if result.action == "accept" and result.data is not None:
        return f"hello {result.data.name}"
    return f"elicitation {result.action}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--transport", choices=["stdio", "sse", "streamable-http"], default="stdio")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    mcp.settings.host = "127.0.0.1"
    mcp.settings.port = args.port
    mcp.run(transport=args.transport)
