"""How far the ref path (what Dart computes) drifts from kiarina's path."""

import json
from pathlib import Path

import numpy as np

LAB_DIR = Path(__file__).resolve().parent.parent
F = json.loads((LAB_DIR / "fixtures/frames.json").read_text())
I = json.loads((LAB_DIR / "fixtures/input.json").read_text())

out = {"warp_vs_cv2_mismatch": I["warp_vs_cv2_mismatch"]}
for name, values in [
    ("face", [e["cos_ref_kiarina"] for f in F for e in f["faces"]["embeddings"] if "cos_ref_kiarina" in e]),
    ("object_crop", [e["cos_ref_kiarina"] for f in F for e in f["objects"]["embeddings"] if "cos_ref_kiarina" in e]),
    ("scene", [f["scene"]["cos_ref_kiarina"] for f in F]),
]:
    out[f"{name}_cos"] = {"n": len(values), "min": min(values), "median": float(np.median(values))}

face_diff, count_diff = [], []
for f in F:
    r, k = f["faces"]["ref"], f["faces"]["kiarina"]
    if len(r) != len(k):
        count_diff.append(f["name"])
        continue
    for a, b in zip(r, k, strict=True):
        face_diff.append(max(abs(x - y) for x, y in zip(a["bbox"] + sum(a["keypoints"], []), b["bbox"] + sum(b["keypoints"], []), strict=True)))
out["faces"] = {"frames_with_other_count": count_diff, "max_coord_diff": max(face_diff) if face_diff else None}

obj_diff, labels, other = [], 0, []
for f in F:
    r, k = f["objects"]["ref"], f["objects"]["kiarina"]
    if len(r) != len(k):
        only = sorted({(o["label"], o["score"]) for o in r} ^ {(o["label"], o["score"]) for o in k})
        other.append({"frame": f["name"], "ref": len(r), "kiarina": len(k)})
        continue
    for a, b in zip(r, k, strict=True):
        obj_diff.append(max(abs(x - y) for x, y in zip(a["bbox"], b["bbox"], strict=True)))
        labels += a["label"] != b["label"]
out["objects"] = {"frames_with_other_count": other, "max_bbox_diff": max(obj_diff) if obj_diff else None, "label_diffs": labels}
print(json.dumps(out, indent=1))
