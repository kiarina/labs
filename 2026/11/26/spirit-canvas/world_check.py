"""Model-free check of a 3D world (Part 11): a room with shapes, panels
(a poster, a clock, a button), the VRM body, a camera move. Drives the
running app through its control port and saves pictures under
work/logs/<name>/.

python3 world_check.py [name] [port]
"""

import base64
import json
import os
import sys
import time
import urllib.parse
import urllib.request

NAME = sys.argv[1] if len(sys.argv) > 1 else "macos"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8813
B = f"http://127.0.0.1:{PORT}"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "logs", NAME)

W = "room"
ROOM = [
    {"id": W, "type": "world", "x": 0, "y": 0, "w": "100%", "h": "100%", "sky": "#CFE3F2",
     "cam_x": 0, "cam_y": 1.7, "cam_z": -4.2, "look_x": 0, "look_y": 1.1, "look_z": 0.5, "fov": 50},
    {"id": "floor", "type": "plane", "in": W, "w": 8, "d": 8, "z": 1, "color": "#C49A6C"},
    {"id": "wall", "type": "box", "in": W, "x": 0, "z": 3, "w": 8, "h": 3, "d": 0.1, "color": "#EFE6D8"},
    {"id": "wall-l", "type": "box", "in": W, "x": -3.5, "z": 1, "w": 0.1, "h": 3, "d": 4, "color": "#E6DCCB"},
    {"id": "desk", "type": "box", "in": W, "x": 1.6, "y": 0.72, "z": 2.2, "w": 1.4, "h": 0.05, "d": 0.7, "color": "#9C6B42"},
    {"id": "desk-leg1", "type": "box", "in": W, "x": 1.0, "z": 2.2, "w": 0.06, "h": 0.72, "d": 0.6, "color": "#7E5634"},
    {"id": "desk-leg2", "type": "box", "in": W, "x": 2.2, "z": 2.2, "w": 0.06, "h": 0.72, "d": 0.6, "color": "#7E5634"},
    {"id": "lamp-pole", "type": "cylinder", "in": W, "x": 2.1, "y": 0.77, "z": 2.4, "w": 0.04, "h": 0.4, "d": 0.04, "color": "#444444"},
    {"id": "lamp", "type": "cone", "in": W, "x": 2.1, "y": 1.1, "z": 2.4, "w": 0.3, "h": 0.22, "d": 0.3, "color": "#FFD98A", "glow": True,
     "tappable": True},
    {"id": "pot", "type": "cylinder", "in": W, "x": -2.6, "z": 2.3, "w": 0.4, "h": 0.4, "d": 0.4, "color": "#C46B4C"},
    {"id": "leaves", "type": "sphere", "in": W, "x": -2.6, "y": 0.35, "z": 2.3, "w": 0.8, "h": 0.9, "d": 0.8, "color": "#5F9A52",
     "tappable": True},
    {"id": "ball", "type": "sphere", "in": W, "x": -1.2, "z": 0.6, "w": 0.35, "h": 0.35, "d": 0.35, "color": "#E2574C",
     "roughness": 0.3, "tappable": True},
    {"id": "ring", "type": "torus", "in": W, "x": -1.9, "y": 1.5, "z": 2.6, "rx": 90, "w": 0.5, "h": 0.5, "d": 0.5,
     "color": "#E2B13C", "metallic": 0.8, "roughness": 0.3},
    {"id": "poster", "type": "text", "in": W, "x": -0.4, "y": 1.3, "z": 2.93, "w": 480, "h": 300, "size_m": 0.9,
     "text": "きょうの予定\n・10:00 散歩\n・14:00 本を読む\n・20:00 おしゃべり", "size": 34, "color": "#3A2F25",
     "background": "#FFFDF6", "radius": 16},
    {"id": "hello", "type": "button", "in": W, "x": 1.6, "y": 0.78, "z": 2.0, "rx": -25, "w": 240, "h": 90, "size_m": 0.16,
     "label": "押してね", "size": 30},
    {"id": "me", "type": "vrm", "in": W, "x": 0.3, "z": 1.2, "ry": -15, "pose": "idle", "tappable": True},
    {"id": "label", "type": "text", "in": W, "x": 0.3, "y": 1.75, "z": 1.2, "w": 260, "h": 70, "size_m": 0.18,
     "face_camera": True, "text": "精霊", "size": 34, "align": "center", "color": "#FFFFFF", "background": "#3B5B8CDD",
     "radius": 30},
]


def post(path, body):
    req = urllib.request.Request(B + path, data=json.dumps(body, ensure_ascii=False).encode(), method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def tool(name, args):
    r = post("/tool?" + urllib.parse.urlencode({"name": name}), args)
    print(name, "->", r["text"][:200])
    return r


def snap(label):
    r = post("/snapshot?" + urllib.parse.urlencode({"name": label, "inline": "1"}), {})
    path = os.path.join(OUT, f"world-{label}.png")
    with open(path, "wb") as f:
        f.write(base64.b64decode(r["png"]))
    print("snapshot", path)


def main():
    os.makedirs(OUT, exist_ok=True)
    tool("canvas_clear", {"background": "#202020"})
    t0 = time.time()
    tool("canvas_put", {"elements": ROOM})
    time.sleep(5)
    snap("1-room")
    # The camera walks up to the desk (a transition of the world's camera).
    tool("canvas_update", {"id": W, "props": {"cam_x": 1.0, "cam_y": 1.4, "cam_z": 0.6, "look_x": 1.6, "look_y": 0.9,
                                              "look_z": 2.2, "fov": 45}, "transition_ms": 2000})
    time.sleep(1.0)
    snap("2-moving")
    time.sleep(1.5)
    snap("3-desk")
    # Back, going round, the body walking.
    tool("canvas_update", {"id": W, "props": {"cam_x": 0, "cam_y": 1.7, "cam_z": -4.2, "look_x": 0, "look_y": 1.1,
                                              "look_z": 0.5, "fov": 50}, "transition_ms": 1500})
    tool("canvas_update", {"id": "me", "props": {"pose": "walk", "ry": 90}})
    tool("canvas_update", {"id": "me", "props": {"x": 1.8}, "transition_ms": 3000})
    tool("canvas_update", {"id": "label", "props": {"x": 1.8}, "transition_ms": 3000})
    time.sleep(1.6)
    snap("4-walking")
    time.sleep(2.0)
    tool("canvas_update", {"id": "me", "props": {"pose": "wave", "ry": 0, "expression": "happy"}})
    tool("canvas_update", {"id": W, "props": {"camera_mode": "orbit", "orbit_speed": 10}})
    time.sleep(3)
    snap("5-orbit")
    tool("canvas_update", {"id": W, "props": {"camera_mode": "fixed"}})
    print("seconds", round(time.time() - t0, 1))


if __name__ == "__main__":
    main()
