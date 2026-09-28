"""Run every client x server x transport combination and save the outcomes.

Clients: v1 (langchain-mcp-adapters on mcp 1.30), v2 (langchain.mcp on mcp 2.2),
sdk (mcp 2.2 alone) and fastmcp (fastmcp-slim[client] alone).
Servers: v1 (mcp 1.30 FastMCP) and v2 (mcp 2.2 MCPServer).
Each side runs from its own uv environment, so the two mcp majors never share
a process. Standard library only.
"""

import json
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRANSPORTS = ["stdio", "sse", "streamable_http"]
PATHS = {"sse": "/sse", "streamable_http": "/mcp"}


def python(env: str) -> str:
    return str(HERE / env / ".venv" / "bin" / "python")


def wait_port(port: int, timeout: float = 20) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.2)
    raise TimeoutError(f"server did not listen on {port}")


def run_one(client: str, server: str, transport: str, mode: str | None, port: int) -> dict:
    server_script = str(HERE / server / "server.py")
    cmd = [python(client), str(HERE / client / "client.py"), "--transport", transport]
    if mode:
        cmd += ["--mode", mode]
    proc = None
    if transport == "stdio":
        cmd += ["--command", python(server), "--args", server_script, "--transport", "stdio"]
    else:
        proc = subprocess.Popen(
            [python(server), server_script, "--transport", transport.replace("_", "-"), "--port", str(port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_port(port)
        cmd += ["--url", f"http://127.0.0.1:{port}{PATHS[transport]}"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        try:
            data = json.loads(res.stdout.strip().splitlines()[-1])
        except (IndexError, json.JSONDecodeError):
            data = {"crashed": True, "returncode": res.returncode, "stderr_tail": res.stderr[-1500:]}
    except subprocess.TimeoutExpired:
        data = {"crashed": True, "error": "client timed out after 180 s"}
    finally:
        if proc:
            proc.terminate()
            proc.wait(10)
    return data


def main() -> None:
    clients = ("v1", "v2", "sdk", "fastmcp")
    combos = [(c, s, t, None) for c in clients for s in ("v1", "v2") for t in TRANSPORTS]
    combos += [(c, s, t, "legacy") for c in clients[1:] for s in ("v1", "v2") for t in ("stdio", "streamable_http")]
    only = sys.argv[1:]
    results = []
    port = 18800
    for client, server, transport, mode in combos:
        key = f"client-{client}__server-{server}__{transport}" + (f"__{mode}" if mode else "")
        if only and not any(o in key for o in only):
            continue
        port += 1
        print(f"== {key}", flush=True)
        data = run_one(client, server, transport, mode, port)
        results.append({"key": key, "client": client, "server": server, "transport": transport,
                        "mode": mode or (None if client == "v1" else "auto"), **data})
    out = HERE / "results" / ("matrix.partial.json" if only else "matrix.json")
    text = json.dumps(results, ensure_ascii=False, indent=2, default=str) + "\n"
    out.write_text(text.replace(str(HERE), "<lab>"))  # keep local paths out of the committed results
    print(f"wrote {out.relative_to(HERE)}")


if __name__ == "__main__":
    main()
