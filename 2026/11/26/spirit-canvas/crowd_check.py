"""Model-free check of several bodies and where they look (Part 15): five VRMs
in a world in a half circle, all looking at the viewer, then at a ball that
moves, then at the one in the middle; then the same five on the 2D canvas.
Saves pictures, memory and frame times under work/logs/<name>/.

Run the app with VRM_DIR set to a folder of .vrm files:
VRM_DIR=<folder> CONTROL_PORT=8813 mise run run
python3 crowd_check.py [name] [port] [vrm names...]
"""

import json
import math
import os
import subprocess
import sys
import time

ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]
import world_check as w  # noqa: E402

NAME = ARGS[0] if ARGS else "macos"
PORT = int(ARGS[1]) if len(ARGS) > 1 else 8813
w.B = f"http://127.0.0.1:{PORT}"
HERE = os.path.dirname(os.path.abspath(__file__))
w.OUT = os.path.join(HERE, "work", "logs", NAME)
LOG = os.path.join(HERE, "work", "logs", "isle-run.log")


def rss_mb():
    pid = subprocess.run(["pgrep", "-f", "spirit_canvas.app/Contents/MacOS/spirit_canvas"],
                         capture_output=True, text=True).stdout.split()[0]
    out = subprocess.run(["footprint", pid], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "phys_footprint:" in line:
            return line.split(":")[1].strip()
    return "?"


def loaded():
    with open(LOG, errors="ignore") as f:
        return f.read().count("Unpacking glTF")


def wait_loaded(before, n, limit=60):
    t0 = time.time()
    while loaded() < before + n and time.time() - t0 < limit:
        time.sleep(0.2)
    return round(time.time() - t0, 1)


def frames(label):
    w.get_frames(reset=True)
    time.sleep(4)
    f = w.get_frames(reset=True)
    print(label, f["fps"], f["build_ms"].get("avg"), f["build_ms"].get("p90"), flush=True)
    return f


def film(label, seconds):
    """Snapshots one after another for a short film (work/logs/<name>/film)."""
    import base64
    import urllib.parse
    d = os.path.join(w.OUT, "film")
    os.makedirs(d, exist_ok=True)
    end, n = time.time() + seconds, 0
    while time.time() < end:
        r = w.post("/snapshot?" + urllib.parse.urlencode({"name": "film", "inline": "1"}), {})
        with open(os.path.join(d, f"{label}-{n:04d}.png"), "wb") as f:
            f.write(base64.b64decode(r["png"]))
        n += 1
    print("film", label, n, "pictures", flush=True)


def to_main_display():
    """A window left on another display may get no frames (0 fps when that
    display sleeps): put it on the main one."""
    subprocess.run(["osascript", "-e", 'tell application "System Events" to set position of window 1 of '
                    '(first process whose bundle identifier is "dev.kiarina.labs.spiritCanvas") to {120, 80}'])


def main():
    os.makedirs(w.OUT, exist_ok=True)
    to_main_display()
    media = json.loads(w.tool("canvas_media", {})["text"])
    names = ARGS[2:] or media["vrm"][:5]
    print("bodies", names)
    out = {"bodies": names}
    w.tool("canvas_clear", {"background": "#000000"})
    out["memory_before"] = rss_mb()
    ids = [f"b{i}" for i in range(len(names))]
    els = [
        {"id": "stage", "type": "world", "x": 0, "y": 0, "w": "100%", "h": "100%", "sky": "#DCE6EE",
         "sun_elevation": 50, "sun_azimuth": -30, "light": 2.6,
         "cam_x": 0, "cam_y": 1.45, "cam_z": -1.6, "look_x": 0, "look_y": 1.05, "look_z": 1.6, "fov": 50},
        {"id": "floor", "type": "cylinder", "in": "stage", "y": -0.1, "z": 1.4, "w": 7, "h": 0.1, "d": 5,
         "color": "#C9B79A"},
        {"id": "ball", "type": "sphere", "in": "stage", "x": -1.9, "y": 1.7, "z": 0.6, "w": 0.3, "h": 0.3,
         "d": 0.3, "color": "#FF7A59", "glow": 1.5},
    ]
    for i, (id_, n) in enumerate(zip(ids, names)):
        a = math.radians(-60 + 120 * i / max(1, len(names) - 1))
        # A half circle opening to the viewer, each turned a little to the middle.
        els.append({"id": id_, "type": "vrm", "in": "stage", "src": n, "x": round(1.7 * math.sin(a), 2),
                    "z": round(2.2 - 1.2 * (1 - math.cos(a)), 2), "ry": round(-math.degrees(a) * 0.6),
                    "pose": "idle", "look_at": "viewer"})
    before = loaded()
    t0 = time.time()
    w.tool("canvas_put", {"elements": els})
    out["world_load_s"] = wait_loaded(before, len(names))
    time.sleep(2)
    out["memory_world"] = rss_mb()
    print("loaded in", out["world_load_s"], "s; memory", out["memory_world"], flush=True)
    w.snap("crowd-1-viewer")
    out["frames_viewer"] = frames("viewer")
    # The ball goes across; everyone follows it.
    for id_ in ids:
        w.tool("canvas_update", {"id": id_, "props": {"look_at": "ball"}})
    time.sleep(1.5)
    w.snap("crowd-2-ball-left")
    w.tool("canvas_update", {"id": "ball", "props": {"x": 1.9, "y": 0.3, "z": 1.0}, "transition_ms": 4000})
    film("ball", 5)
    w.snap("crowd-4-ball-right")
    out["frames_ball"] = frames("ball")
    # All at the middle one, and the middle one at the first.
    mid = ids[len(ids) // 2]
    for id_ in ids:
        w.tool("canvas_update", {"id": id_, "props": {"look_at": ids[0] if id_ == mid else mid}})
    w.tool("canvas_update", {"id": mid, "props": {"pose": "wave", "expression": "happy"}})
    time.sleep(1.5)
    w.snap("crowd-5-middle")
    # The same bodies on the 2D canvas, side by side.
    w.tool("canvas_clear", {"background": "#20242C"})
    time.sleep(1)
    before = loaded()
    w.tool("canvas_put", {"elements": [
        {"id": f"p{i}", "type": "vrm", "src": n, "x": f"{i * 20}%", "y": "8%", "w": "20%", "h": "84%",
         "framing": "full", "pose": ["wave", "idle", "cheer", "think", "nod"][i % 5],
         "expression": ["happy", "neutral", "happy", "relaxed", "surprised"][i % 5]}
        for i, n in enumerate(names)]})
    out["canvas_load_s"] = wait_loaded(before, len(names))
    time.sleep(2)
    out["memory_canvas"] = rss_mb()
    print("2D loaded in", out["canvas_load_s"], "s; memory", out["memory_canvas"], flush=True)
    w.snap("crowd-6-canvas")
    out["frames_canvas"] = frames("canvas")
    with open(os.path.join(w.OUT, "crowd.json"), "w") as f:
        json.dump(out, f, indent=1)


if __name__ == "__main__":
    main()
