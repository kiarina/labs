"""Model-free check of .vrma motions on several bodies (Part 16): five VRMs in
a world, each with its own motion (and a chair for the one sitting), then
every body changes motion (blended), one plays once and returns to its pose;
then the same on the 2D canvas. Pictures, a short film and frame times go
under work/logs/<name>/.

VRM_DIR=<folder of .vrm> CONTROL_PORT=8813 mise run run   (VRMA_DIR: make_vrma_motions.py's)
python3 motion_check.py [name] [port] [vrm names...]
"""

import json
import os
import sys
import time

ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]
import world_check as w  # noqa: E402
from crowd_check import film, frames, loaded, rss_mb, to_main_display, wait_loaded  # noqa: E402

NAME = ARGS[0] if ARGS else "macos"
PORT = int(ARGS[1]) if len(ARGS) > 1 else 8813
w.B = f"http://127.0.0.1:{PORT}"
w.OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "logs", NAME)

FIRST = ["dance", "jump", "run", "clap", "sit"]
SECOND = ["stretch", "spin", "sway", "dance", "clap"]


def main():
    os.makedirs(w.OUT, exist_ok=True)
    to_main_display()
    media = json.loads(w.tool("canvas_media", {})["text"])
    print("vrma", media["vrma"], flush=True)
    names = ARGS[2:] or media["vrm"][:5]
    out = {"bodies": names}
    w.tool("canvas_clear", {"background": "#000000"})
    ids = [f"m{i}" for i in range(len(names))]
    xs = [-2.0, -1.0, 0.0, 1.0, 2.0]
    els = [
        {"id": "stage", "type": "world", "x": 0, "y": 0, "w": "100%", "h": "100%", "sky": "#DCE6EE",
         "sun_elevation": 50, "sun_azimuth": -30, "light": 2.6,
         "cam_x": 0, "cam_y": 1.4, "cam_z": -2.6, "look_x": 0, "look_y": 0.95, "look_z": 1.5, "fov": 50},
        {"id": "floor", "type": "cylinder", "in": "stage", "y": -0.1, "z": 1.4, "w": 7, "h": 0.1, "d": 5,
         "color": "#C9B79A"},
        # A chair for the one sitting (seat 0.45 m).
        {"id": "seat", "type": "box", "in": "stage", "x": xs[4], "z": 1.75, "w": 0.5, "h": 0.42, "d": 0.45,
         "color": "#7A5236"},
        {"id": "back", "type": "box", "in": "stage", "x": xs[4], "y": 0.42, "z": 2.0, "w": 0.5, "h": 0.5,
         "d": 0.06, "color": "#7A5236"},
    ]
    for i, (id_, n) in enumerate(zip(ids, names)):
        els.append({"id": id_, "type": "vrm", "in": "stage", "src": n, "x": xs[i], "z": 1.6,
                    "animation": FIRST[i], "look_at": "viewer"})
    before = loaded()
    w.tool("canvas_put", {"elements": els})
    out["load_s"] = wait_loaded(before, len(names))
    time.sleep(2)
    out["memory"] = rss_mb()
    w.snap("motion-1")
    time.sleep(0.4)
    w.snap("motion-1b")
    out["frames_world"] = frames("world")
    film("motion", 4)
    # Everyone changes motion (blended); the jumper spins once, then poses.
    for i, id_ in enumerate(ids):
        props = {"animation": SECOND[i]}
        if SECOND[i] == "spin":
            props.update({"animation_loop": False, "pose": "wave", "expression": "happy"})
        w.tool("canvas_update", {"id": id_, "props": props})
    time.sleep(0.15)
    w.snap("motion-2-blending")
    time.sleep(1.2)
    w.snap("motion-3-second")
    time.sleep(2)
    w.snap("motion-4-after-once")
    # Faster dancing.
    w.tool("canvas_update", {"id": ids[3], "props": {"animation_speed": 2}})
    # The same on the 2D canvas.
    w.tool("canvas_clear", {"background": "#20242C"})
    before = loaded()
    w.tool("canvas_put", {"elements": [
        {"id": f"p{i}", "type": "vrm", "src": n, "x": f"{i * 20}%", "y": "8%", "w": "20%", "h": "84%",
         "framing": "full", "animation": FIRST[i] if FIRST[i] != "sit" else "sway"}
        for i, n in enumerate(names)]})
    out["load_2d_s"] = wait_loaded(before, len(names))
    time.sleep(2)
    w.snap("motion-5-canvas")
    out["frames_2d"] = frames("2d")
    with open(os.path.join(w.OUT, "motion.json"), "w") as f:
        json.dump(out, f, indent=1)
    print(json.dumps({k: v for k, v in out.items() if not k.startswith("frames")}), flush=True)


if __name__ == "__main__":
    main()
