"""Similarity distributions in the replay stream, to choose the tracker's thresholds.

Reads the ref embeddings of fixtures/frames.json (work/fixtures-bin) and prints
cosine similarities for: faces within and across segments, the same object
label in consecutive frames vs different labels, and whole frames within and
across segments.
"""

import json
from itertools import combinations
from pathlib import Path

import numpy as np

LAB = Path(__file__).resolve().parent.parent
F = [f for f in json.loads((LAB / "fixtures/frames.json").read_text()) if f["group"] == "stream"]


def vec(name: str) -> np.ndarray:
    return np.frombuffer((LAB / f"work/fixtures-bin/{name}.f32").read_bytes(), "<f4")


def stats(values: list[float]) -> dict[str, float]:
    if not values:
        return {}
    a = np.asarray(values)
    return {"n": len(a), "min": round(float(a.min()), 3), "p10": round(float(np.percentile(a, 10)), 3), "median": round(float(np.median(a)), 3), "max": round(float(a.max()), 3)}


faces = []  # (frame, segment, x-center, vector)
for f in F:
    for i, (det, e) in enumerate(zip(f["faces"]["ref"], f["faces"]["embeddings"], strict=True)):
        faces.append((f["name"], f["segment"], (det["bbox"][0] + det["bbox"][2]) / 2, vec(f"{f['name']}.face{i}")))

# in the dialogue clip the two people sit left (x < 0.5) and right
def who(face):
    return None if not face[1].startswith("dialogue") else ("left" if face[2] < 0.5 else "right")

same, diff, crowd = [], [], []
for a, b in combinations(faces, 2):
    c = float(a[3] @ b[3])
    wa, wb = who(a), who(b)
    if wa and wb:
        (same if wa == wb else diff).append(c)
    else:
        crowd.append(c)
across = [float(a[3] @ b[3]) for a, b in combinations(faces, 2) if who(a) and who(a) == who(b) and a[1] != b[1]]
print("faces: same person", stats(same), "\n  same person, a vs b segment", stats(across), "\n  different people", stats(diff), "\n  with the crowd frame", stats(crowd))
print("  who:", sorted({(f[1], who(f)) for f in faces}))

objs = []
for f in F:
    for e in f["objects"]["embeddings"]:
        o = f["objects"]["ref"][e["index"]]
        rank = f["objects"]["embeddings"].index(e)
        objs.append((f["name"], f["segment"], o["label"], o["bbox"], vec(f"{f['name']}.object{rank}")))

def iou(a, b):
    iw = min(a[2], b[2]) - max(a[0], b[0]); ih = min(a[3], b[3]) - max(a[1], b[1])
    inter = max(iw, 0) * max(ih, 0)
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / u if u > 0 else 0

names = [f["name"] for f in F]
same_track, same_label_other, other_label = [], [], []
for a, b in combinations(objs, 2):
    c = float(a[4] @ b[4])
    adjacent = abs(names.index(a[0]) - names.index(b[0])) == 1 and a[1] == b[1]
    if a[2] == b[2] and adjacent and iou(a[3], b[3]) > 0.5:
        same_track.append(c)
    elif a[2] == b[2]:
        same_label_other.append(c)
    else:
        other_label.append(c)
print("objects: same label, next frame, IoU>0.5", stats(same_track), "\n  same label otherwise", stats(same_label_other), "\n  different label", stats(other_label))
print("  labels:", sorted({(o[1], o[2]) for o in objs}))

scenes = [(f["name"], f["segment"], vec(f"{f['name']}.scene")) for f in F]
consec = [float(scenes[i][2] @ scenes[i + 1][2]) for i in range(len(scenes) - 1) if scenes[i][1] == scenes[i + 1][1]]
cut = [(scenes[i][0], scenes[i + 1][0], round(float(scenes[i][2] @ scenes[i + 1][2]), 3)) for i in range(len(scenes) - 1) if scenes[i][1] != scenes[i + 1][1]]
dia = [float(a[2] @ b[2]) for a, b in combinations(scenes, 2) if a[1] == "dialogue_a" and b[1] == "dialogue_b"]
other = [float(a[2] @ b[2]) for a, b in combinations(scenes, 2) if a[1] != b[1] and {a[1], b[1]} != {"dialogue_a", "dialogue_b"}]
print("scenes: consecutive, same segment", stats(consec), "\n  cuts", cut, "\n  dialogue a vs b (the same place again)", stats(dia), "\n  different places", stats(other))

# Re-identification after leaving: a face compared with everything a track kept
# (the best of the track's embeddings), the way SightAnalyzer matches.
stills = [f for f in json.loads((LAB / "fixtures/frames.json").read_text()) if f["group"] == "still"]
strangers = [vec(f"{f['name']}.face{i}") for f in stills for i in range(len(f["faces"]["ref"]))]
strangers += [x[3] for x in faces if x[1] == "crowd"]
track = {side: [x[3] for x in faces if x[1] == "dialogue_a" and who(x) == side] for side in ("left", "right")}
back = [max(float(v @ t) for t in track["left"]) for v in [x[3] for x in faces if x[1] == "dialogue_b"]]
false = [max(float(v @ t) for t in track[s]) for v in strangers for s in track]
print("re-identification: dialogue_b face vs the left track of dialogue_a (best of track)", stats(back))
print("  strangers (stills and crowd) vs either track (best of track)", stats(false))
