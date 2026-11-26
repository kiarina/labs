"""Model-free check of the rich 3D scene (Part 12, scenes/spirit-isle.json):
loads it, goes through dusk, the crystal, night, closer, round and morning,
saving pictures and frame times under work/logs/<name>/.

python3 isle_check.py [name] [port] [steps]
steps: a comma list of the steps to run (default all)
"""

import base64
import json
import os
import sys
import time
import urllib.parse

from world_check import OUT as _OUT, get_frames, post, snap, tool  # noqa: F401
import world_check

NAME = sys.argv[1] if len(sys.argv) > 1 else "macos"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8813
world_check.B = f"http://127.0.0.1:{PORT}"
world_check.OUT = OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "logs", NAME)
STEPS = sys.argv[3].split(",") if len(sys.argv) > 3 else None


def event(kind, id, value=None):
    q = {"kind": kind, "id": id}
    if value is not None:
        q["value"] = json.dumps(value)
    post("/event?" + urllib.parse.urlencode(q), {})


def state(key, value):
    tool("canvas_state", {"set": {key: value}})


def frames(label, seconds):
    get_frames(reset=True)
    time.sleep(seconds)
    f = get_frames(reset=True)
    print(label, json.dumps(f))
    return f


def film(label, seconds):
    """Snapshots one after another (as fast as they come) for a short film."""
    d = os.path.join(OUT, "film")
    os.makedirs(d, exist_ok=True)
    end, n = time.time() + seconds, 0
    while time.time() < end:
        r = post("/snapshot?" + urllib.parse.urlencode({"name": "film", "inline": "1"}), {})
        with open(os.path.join(d, f"{label}-{n:04d}.png"), "wb") as f:
            f.write(base64.b64decode(r["png"]))
        n += 1
    print("film", label, n, "pictures in", seconds, "s")


def main():
    os.makedirs(OUT, exist_ok=True)
    out = {}
    t0 = time.time()
    tool("canvas_load", {"name": "spirit-isle"})
    print("load", round(time.time() - t0, 2))
    time.sleep(2.5)
    snap("isle-0-coming-in")
    time.sleep(6)
    snap("isle-1-dusk")
    out["dusk"] = frames("dusk", 5)
    event("tap", "crystal", {"x": 2.7, "y": 1.6, "z": 2.4})
    time.sleep(0.35)
    snap("isle-2-crystal")
    time.sleep(2.5)
    state("time", "night")
    if "film" in (STEPS or []):
        film("night", 8)
    else:
        time.sleep(3.5)
        snap("isle-3-to-night")
        time.sleep(5)
    snap("isle-4-night")
    out["night"] = frames("night", 5)
    state("closers", 1)
    time.sleep(2.8)
    snap("isle-5-closer")
    state("backs", 1)
    time.sleep(2.2)
    state("turns", 1)
    if "film" in (STEPS or []):
        time.sleep(1.5)
        film("round", 12)
        time.sleep(1.5)
    else:
        time.sleep(5)
        snap("isle-6-round")
        out["round"] = frames("round", 6)
        time.sleep(4)
    state("time", "morning")
    time.sleep(7)
    snap("isle-7-morning")
    out["morning"] = frames("morning", 5)
    if "film" in (STEPS or []):
        return
    with open(os.path.join(OUT, "isle-frames.json"), "w") as f:
        json.dump(out, f, indent=1)


if __name__ == "__main__":
    main()
