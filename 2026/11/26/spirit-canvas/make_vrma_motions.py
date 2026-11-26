"""Writes VRM Animation (.vrma) motions without any tool (Part 16): a T-pose
humanoid skeleton (VRMC_vrm_animation) and keyframes of the bones'
rotations (and the hips' place). Rotations are in VRM's normalized space:
the model faces +Z, its left is +X, y is up; the rest pose is the T-pose.

python3 make_vrma_motions.py

Writes work/assets/vrma/<name>.vrma for: dance, jump, run, clap, stretch,
spin, sit, sway. Give that folder as VRMA_DIR.
"""

import json
import math
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "work", "assets", "vrma")

# Bone, parent, rest offset from the parent (metres).
SKELETON = [
    ("hips", None, (0, 0.95, 0)),
    ("spine", "hips", (0, 0.1, 0)),
    ("chest", "spine", (0, 0.12, 0)),
    ("upperChest", "chest", (0, 0.12, 0)),
    ("neck", "upperChest", (0, 0.13, 0)),
    ("head", "neck", (0, 0.08, 0)),
    ("leftShoulder", "upperChest", (0.03, 0.1, 0)),
    ("leftUpperArm", "leftShoulder", (0.1, 0, 0)),
    ("leftLowerArm", "leftUpperArm", (0.27, 0, 0)),
    ("leftHand", "leftLowerArm", (0.25, 0, 0)),
    ("rightShoulder", "upperChest", (-0.03, 0.1, 0)),
    ("rightUpperArm", "rightShoulder", (-0.1, 0, 0)),
    ("rightLowerArm", "rightUpperArm", (-0.27, 0, 0)),
    ("rightHand", "rightLowerArm", (-0.25, 0, 0)),
    ("leftUpperLeg", "hips", (0.09, -0.05, 0)),
    ("leftLowerLeg", "leftUpperLeg", (0, -0.42, 0)),
    ("leftFoot", "leftLowerLeg", (0, -0.42, 0)),
    ("rightUpperLeg", "hips", (-0.09, -0.05, 0)),
    ("rightLowerLeg", "rightUpperLeg", (0, -0.42, 0)),
    ("rightFoot", "rightLowerLeg", (0, -0.42, 0)),
]
HIPS_Y = 0.95


def q(axis, deg):
    """A rotation of deg degrees about axis 'x', 'y' or 'z' as (x, y, z, w)."""
    h = math.radians(deg) / 2
    s = math.sin(h)
    return {"x": (s, 0, 0, math.cos(h)), "y": (0, s, 0, math.cos(h)), "z": (0, 0, s, math.cos(h))}[axis]


def mul(*qs):
    x, y, z, w = 0, 0, 0, 1
    for bx, by, bz, bw in qs:
        x, y, z, w = (w * bx + x * bw + y * bz - z * by, w * by - x * bz + y * bw + z * bx,
                      w * bz + x * by - y * bx + z * bw, w * bw - x * bx - y * by - z * bz)
    return (x, y, z, w)


# Helpers in plain words. Arms: "down" from the T-pose, "forward" to the
# front, "up" overhead. Legs: "lift" forward, knees "bend" back.
def arm(side, down=0, forward=0, twist=0):
    s = 1 if side == "left" else -1
    return mul(q("y", -s * forward), q("z", -s * down), q("x", twist))


def elbow(side, bend):
    s = 1 if side == "left" else -1
    return q("y", -s * bend)


def leg(lift=0, out=0, side="left"):
    s = 1 if side == "left" else -1
    return mul(q("x", -lift), q("z", s * out))


def knee(bend):
    return q("x", bend)


def wave(t, period, lo, hi, phase=0.0):
    return lo + (hi - lo) * (0.5 - 0.5 * math.cos(2 * math.pi * (t / period + phase)))


def motion_dance(t):
    """Side steps with the arms up in turn, the body swinging."""
    p = 2.0
    side = math.sin(2 * math.pi * t / p)
    up = 0.5 + 0.5 * math.sin(2 * math.pi * t / p)
    return {
        "hips": mul(q("y", 12 * side), q("z", 4 * side)),
        "spine": q("z", -6 * side),
        "chest": q("z", -5 * side),
        "head": q("z", 8 * side),
        "leftUpperArm": arm("left", down=-60 + 110 * (1 - up), forward=15),
        "leftLowerArm": elbow("left", 30 + 40 * up),
        "rightUpperArm": arm("right", down=-60 + 110 * up, forward=15),
        "rightLowerArm": elbow("right", 30 + 40 * (1 - up)),
        "leftUpperLeg": leg(lift=10 * max(0, side), out=6),
        "leftLowerLeg": knee(20 * max(0, side)),
        "rightUpperLeg": leg(lift=10 * max(0, -side), out=6, side="right"),
        "rightLowerLeg": knee(20 * max(0, -side)),
        "_hips": (0.06 * side, HIPS_Y - 0.03 * abs(math.sin(2 * math.pi * t / p * 2)), 0),
    }, p


def motion_jump(t):
    """Crouch, jump up with the arms high, land."""
    p = 1.4
    u = (t % p) / p
    if u < 0.3:      # crouch
        c, y = u / 0.3, 0
    elif u < 0.65:   # in the air
        c, y = 0, math.sin(math.pi * (u - 0.3) / 0.35) * 0.3
    else:            # land and stand
        c, y = max(0, 1 - (u - 0.65) / 0.35) * 0.8, 0
    air = y / 0.3
    return {
        "spine": q("x", 18 * c),
        "leftUpperLeg": leg(lift=55 * c + 10 * air),
        "rightUpperLeg": leg(lift=55 * c + 10 * air, side="right"),
        "leftLowerLeg": knee(95 * c + 20 * air),
        "rightLowerLeg": knee(95 * c + 20 * air),
        "leftFoot": q("x", -35 * c),
        "rightFoot": q("x", -35 * c),
        "leftUpperArm": arm("left", down=75 - 150 * air + 20 * c, forward=-30 * c),
        "rightUpperArm": arm("right", down=75 - 150 * air + 20 * c, forward=-30 * c),
        "_hips": (0, HIPS_Y - 0.28 * c + y, 0),
    }, p


def motion_run(t):
    """Running on the spot: legs and arms swinging, the body bobbing."""
    p = 0.7
    s = math.sin(2 * math.pi * t / p)
    return {
        "spine": q("x", 10),
        "leftUpperLeg": leg(lift=40 * s),
        "rightUpperLeg": leg(lift=-40 * s, side="right"),
        "leftLowerLeg": knee(30 + 60 * max(0, -s)),
        "rightLowerLeg": knee(30 + 60 * max(0, s)),
        "leftUpperArm": arm("left", down=75, forward=-45 * s),
        "rightUpperArm": arm("right", down=75, forward=45 * s),
        "leftLowerArm": elbow("left", 80),
        "rightLowerArm": elbow("right", 80),
        "_hips": (0, HIPS_Y - 0.03 + 0.04 * abs(s), 0),
    }, p


def motion_clap(t):
    """Clapping in front of the chest."""
    p = 0.5
    o = wave(t, p, 0, 1)
    return {
        # Upper arms forward and a little down, forearms in to meet at the chest.
        "leftUpperArm": arm("left", down=30, forward=70 + 12 * (1 - o)),
        "rightUpperArm": arm("right", down=30, forward=70 + 12 * (1 - o)),
        "leftLowerArm": elbow("left", 80 - 30 * o),
        "rightLowerArm": elbow("right", 80 - 30 * o),
        "head": q("x", -4 + 6 * o),
    }, p


def motion_stretch(t):
    """A long stretch: arms up, leaning back, then side to side."""
    p = 4.0
    up = wave(t, p, 0.2, 1)
    side = math.sin(4 * math.pi * t / p) * up
    return {
        "spine": mul(q("x", -10 * up), q("z", 12 * side)),
        "chest": mul(q("x", -8 * up), q("z", 8 * side)),
        "head": q("x", -12 * up),
        "leftUpperArm": arm("left", down=75 - 160 * up),
        "rightUpperArm": arm("right", down=75 - 160 * up),
        "leftLowerArm": elbow("left", 20 * (1 - up)),
        "rightLowerArm": elbow("right", 20 * (1 - up)),
    }, p


def motion_spin(t):
    """One full turn with the arms out (once round in 1.6 s)."""
    p = 1.6
    u = (t % p) / p
    return {
        "hips": q("y", 360 * (u * u * (3 - 2 * u))),
        "leftUpperArm": arm("left", down=20),
        "rightUpperArm": arm("right", down=20),
        "head": q("x", -6),
        "_hips": (0, HIPS_Y + 0.02 * math.sin(math.pi * u), 0),
    }, p


def motion_sit(t):
    """Sitting on a chair about 0.45 m high, hands on the knees, breathing."""
    p = 4.0
    b = math.sin(2 * math.pi * t / p)
    return {
        "spine": q("x", 4 + 2 * b),
        "head": q("x", 3 * b),
        "leftUpperLeg": leg(lift=88, out=6),
        "rightUpperLeg": leg(lift=88, out=6, side="right"),
        "leftLowerLeg": knee(88),
        "rightLowerLeg": knee(88),
        "leftUpperArm": arm("left", down=68, forward=35),
        "rightUpperArm": arm("right", down=68, forward=35),
        "leftLowerArm": elbow("left", 30),
        "rightLowerArm": elbow("right", 30),
        # The hips go back and down onto the seat.
        "_hips": (0, 0.47, -0.05),
    }, p


def motion_sway(t):
    """Swaying gently with the music, hands behind the back."""
    p = 2.4
    s = math.sin(2 * math.pi * t / p)
    return {
        "hips": q("z", 3 * s),
        "spine": q("z", -4 * s),
        "head": mul(q("z", 7 * s), q("x", 3)),
        "leftUpperArm": arm("left", down=70, forward=-25),
        "rightUpperArm": arm("right", down=70, forward=-25),
        "leftLowerArm": elbow("left", -40),
        "rightLowerArm": elbow("right", -40),
        "_hips": (0.02 * s, HIPS_Y, 0),
    }, p


MOTIONS = {
    "dance": motion_dance, "jump": motion_jump, "run": motion_run, "clap": motion_clap,
    "stretch": motion_stretch, "spin": motion_spin, "sit": motion_sit, "sway": motion_sway,
}


def write_vrma(name, fn, fps=30):
    _, period = fn(0)
    n = int(round(period * fps)) + 1
    times = [i / fps for i in range(n)]
    frames = [fn(t)[0] for t in times]
    bones = sorted({k for f in frames for k in f if not k.startswith("_")})
    index = {b: i for i, (b, _, _) in enumerate(SKELETON)}
    blob = bytearray()
    accessors, views = [], []

    def add(floats, kind, count, minmax=False):
        off = len(blob)
        blob.extend(struct.pack(f"<{len(floats)}f", *floats))
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(floats) * 4})
        a = {"bufferView": len(views) - 1, "componentType": 5126, "count": count, "type": kind}
        if minmax:
            a["min"], a["max"] = [min(floats)], [max(floats)]
        accessors.append(a)
        return len(accessors) - 1

    t_acc = add(times, "SCALAR", n, minmax=True)
    samplers, channels = [], []
    for b in bones:
        vals = []
        for f in frames:
            vals.extend(f.get(b, (0, 0, 0, 1)))
        samplers.append({"input": t_acc, "output": add(vals, "VEC4", n), "interpolation": "LINEAR"})
        channels.append({"sampler": len(samplers) - 1, "target": {"node": index[b], "path": "rotation"}})
    if any("_hips" in f for f in frames):
        vals = []
        for f in frames:
            vals.extend(f.get("_hips", (0, HIPS_Y, 0)))
        samplers.append({"input": t_acc, "output": add(vals, "VEC3", n), "interpolation": "LINEAR"})
        channels.append({"sampler": len(samplers) - 1, "target": {"node": index["hips"], "path": "translation"}})
    nodes = []
    for b, parent, off in SKELETON:
        nodes.append({"name": b, "translation": list(off)})
    for i, (b, parent, _) in enumerate(SKELETON):
        if parent:
            nodes[index[parent]].setdefault("children", []).append(i)
    gltf = {
        "asset": {"version": "2.0", "generator": "spirit-canvas make_vrma_motions.py"},
        "extensionsUsed": ["VRMC_vrm_animation"],
        "extensions": {"VRMC_vrm_animation": {"specVersion": "1.0", "humanoid": {
            "humanBones": {b: {"node": index[b]} for b, _, _ in SKELETON}}}},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": nodes,
        "animations": [{"name": name, "samplers": samplers, "channels": channels}],
        "buffers": [{"byteLength": len(blob)}], "bufferViews": views, "accessors": accessors,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    blob += b"\0" * (-len(blob) % 4)
    total = 12 + 8 + len(js) + 8 + len(blob)
    data = (struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(js), 0x4E4F534A) + js
            + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))
    path = os.path.join(OUT, f"{name}.vrma")
    with open(path, "wb") as fh:
        fh.write(data)
    return path, len(data), period


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in MOTIONS.items():
        path, size, period = write_vrma(name, fn)
        print(f"{name}: {period:.1f} s, {size} bytes")
