"""Model-free check of a Blender model in a world (Part 13): loads the floating
island (spirit-isle), puts the windmill made by make_windmill_model.py on it,
plays its animations, touches it, and saves pictures and frame times under
work/logs/<name>/.

python3 model_check.py [name] [port]
"""

import json
import os
import sys
import time
import urllib.parse

ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]
import world_check as w  # noqa: E402

NAME = ARGS[0] if ARGS else "macos"
PORT = int(ARGS[1]) if len(ARGS) > 1 else 8813
w.B = f"http://127.0.0.1:{PORT}"
w.OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "logs", NAME)

MILL = {"id": "mill", "type": "model", "in": "isle", "src": "models/windmill.glb", "x": -4.0, "z": 7.6, "ry": 25,
        "animation": "all", "tappable": True,
        # Touched: the blades go fast (handled on the canvas, without the spirit).
        "on": {"tap": [{"do": "update", "id": "mill", "props": {"animation_speed": 4}}]}}
# The same file twice more, smaller, on the floating islets.
SMALL = [dict(MILL, id="mill-b", x=-11, y=2.8, z=11, scale=0.45, ry=10, tappable=False),
         dict(MILL, id="mill-c", x=13, y=1.5, z=-3.5, scale=0.4, ry=-60, animation="spin", tappable=False)]


def main():
    os.makedirs(w.OUT, exist_ok=True)
    w.tool("canvas_load", {"name": "spirit-isle"})
    time.sleep(8.5)
    print(w.tool("canvas_media", {})["text"][-200:])
    t0 = time.time()
    w.tool("canvas_put", {"elements": [MILL] + SMALL})
    time.sleep(1.5)
    print("put", round(time.time() - t0, 2))
    w.snap("model-1-isle")
    # Up to the windmill.
    w.tool("canvas_update", {"id": "isle", "props": {"cam_x": -1.6, "cam_y": 2.0, "cam_z": 2.4, "look_x": -4.0,
                                                     "look_y": 2.0, "look_z": 7.6, "fov": 45}, "transition_ms": 1500})
    time.sleep(2)
    w.snap("model-2-close")
    time.sleep(0.5)
    w.snap("model-2b-close")
    if "hold" in ARGS:
        return  # left on the windmill, for a real click
    w.get_frames(reset=True)
    time.sleep(4)
    frames = w.get_frames(reset=True)
    print("frames", json.dumps(frames))
    # Faster, and night (the window glows).
    w.tool("canvas_update", {"id": "mill", "props": {"animation_speed": 3}})
    w.tool("canvas_state", {"set": {"time": "night"}})
    time.sleep(7)
    w.snap("model-3-night-fast")
    # Only the flag, then still.
    w.tool("canvas_update", {"id": "mill", "props": {"animation": "flag"}})
    time.sleep(1)
    w.snap("model-4-flag-only")
    with open(os.path.join(w.OUT, "model-frames.json"), "w") as f:
        json.dump(frames, f, indent=1)


if __name__ == "__main__":
    main()
