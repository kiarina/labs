"""Echo peer on aiortc (what the server-side spirit host uses).

Joins bin/signal.dart, links with role offer or answer, echoes every frame of
the data channel back verbatim, and on J{"op":"close"} closes the peer
connection, on J{"op":"kill"} exits the process without closing.

    uv run echo.py ws://127.0.0.1:8899 answer
"""

import asyncio
import json
import os
import sys

import websockets
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from aiortc.sdp import candidate_from_sdp


async def main(url: str, role: str) -> None:
    async with websockets.connect(url + "/ws", max_size=None) as ws:
        pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        done = asyncio.Event()

        def wire(dc):
            @dc.on("message")
            def on_message(m):
                if isinstance(m, str) and m.startswith('J{"op":'):
                    op = json.loads(m[1:])["op"]
                    if op == "kill":
                        os._exit(0)
                    asyncio.ensure_future(pc.close()).add_done_callback(lambda _: done.set())
                    return
                dc.send(m)

        @pc.on("datachannel")
        def on_dc(dc):
            wire(dc)

        @pc.on("connectionstatechange")
        async def on_state():
            print("pc", pc.connectionState, flush=True)
            if pc.connectionState in ("failed", "closed"):
                done.set()

        early = []
        remote_set = False

        async def add_candidate(m):
            s = m.get("candidate") or ""
            if not s:
                return
            c = candidate_from_sdp(s.split(":", 1)[1] if s.startswith("candidate:") else s)
            c.sdpMid = m.get("sdpMid")
            c.sdpMLineIndex = m.get("sdpMLineIndex")
            if remote_set:
                await pc.addIceCandidate(c)
            else:
                early.append(c)

        async def set_remote(type_, sdp):
            nonlocal remote_set
            await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type=type_))
            remote_set = True
            for c in early:
                await pc.addIceCandidate(c)
            early.clear()

        async for raw in ws:
            m = json.loads(raw)
            if m["k"] == "peer":
                if role == "offer":
                    wire(pc.createDataChannel("nerve", ordered=True))
                    await pc.setLocalDescription(await pc.createOffer())
                    # aiortc gathers before returning: candidates are in the SDP.
                    await ws.send(json.dumps({"k": "offer", "sdp": pc.localDescription.sdp}))
                break

        async def signals():
            async for raw in ws:
                m = json.loads(raw)
                if m["k"] == "offer":
                    await set_remote("offer", m["sdp"])
                    await pc.setLocalDescription(await pc.createAnswer())
                    await ws.send(json.dumps({"k": "answer", "sdp": pc.localDescription.sdp}))
                elif m["k"] == "answer":
                    await set_remote("answer", m["sdp"])
                elif m["k"] == "cand":
                    await add_candidate(m)

        task = asyncio.ensure_future(signals())
        await done.wait()
        task.cancel()
        await pc.close()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "answer"))
