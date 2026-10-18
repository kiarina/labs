"""Python reference fixtures for the Dart port of kiarina-agi-image.

For every input frame this records two paths:

- kiarina: the real kiarina-agi-image helpers (detect_faces / crop_align_faces /
  embed_image(face) with YuNet and SFace on OpenCV DNN; detect_objects /
  crop_objects / embed_image(object) with D-FINE and SigLIP2 on ONNX Runtime).
- ref: what the Dart port computes, in numpy: YuNet and SFace on ONNX Runtime
  (tools/convert_yunet.py, tools/ref_yunet.py), the face warp of
  tools/ref_warp.py, and OpenCV's generic fixed-point resize
  (tools/ref_resize.py) in front of D-FINE and SigLIP2.

The Dart port is checked against ref (preprocessed bytes by sha256, model
outputs by value), and ref against kiarina (how far the two paths drift).

Outputs:
  fixtures/input.json, fixtures/frames.json        (committed)
  work/frames/<name>.rgb                           (RGB24 frames, gitignored)
  work/fixtures-bin/<name>.<what>.f32              (embeddings, gitignored)

Usage (from the lab directory, after tools/convert_yunet.py):
  uv run --project tools python tools/make_fixtures.py
"""

import asyncio
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import numpy as np

LAB_DIR = Path(__file__).resolve().parent.parent
ASSETS = LAB_DIR.parent.parent.parent.parent / "tests" / "assets"
FIXTURES_DIR = LAB_DIR / "fixtures"
FRAMES_DIR = LAB_DIR / "work" / "frames"
BIN_DIR = LAB_DIR / "work" / "fixtures-bin"
YUNET_ORT = LAB_DIR / "models" / "yunet" / "yunet_2023mar_dequantized.onnx"

os.environ.setdefault(
    "KIARINA_UTILS_APP_USER_CACHE_DIR", str(LAB_DIR / "models" / "kiarina-cache")
)

import cv2  # noqa: E402
import onnxruntime as ort  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ref_resize import resize_linear  # noqa: E402
from ref_warp import warp_affine  # noqa: E402
from ref_yunet import YuNetOrt, make_blob  # noqa: E402

from kiarina.agi.image_detection_model import (  # noqa: E402
    crop_align_faces,
    crop_objects,
    detect_faces,
    detect_objects,
)
from kiarina.agi.image_detection_model._helpers.crop_align_faces import (  # noqa: E402
    _ARCFACE_DST,
    _umeyama,
)
from kiarina.agi.image_embedding_model import embed_image  # noqa: E402
from kiarina.agi.run_context import RunContext  # noqa: E402
from kiarina.utils.app import configure as configure_app  # noqa: E402

ort.set_default_logger_severity(3)

STILLS = [
    ("many_face", "jpg/many_face_1280x720_275kb.jpg"),
    ("objects", "jpg/objects_1536x1024_358kb.jpg"),
    ("street", "jpg/street_scene_1774x887_287kb.jpg"),
]

# The replay stream: one 768x512 "camera" at 2 fps. The two people of the
# dialogue clip appear, leave (door, glass, a crowd photo) and come back in
# later frames of the same clip, so re-identification has something to find.
STREAM_W, STREAM_H, STREAM_FPS = 768, 512, 2
STREAM = [
    ("dialogue_a", "mp4/ltx2_dialogue_512x512_24fps_7s_355kb.mp4", 0.0, 3.5),
    ("door", "mp4/door_open_768x512_24fps_8s_302kb.mp4", 0.0, 8.0),
    ("crowd", "jpg/many_face_1280x720_275kb.jpg", None, 2.0),
    ("glass", "mp4/glass_fall_768x512_24fps_8s_490kb.mp4", 0.0, 8.0),
    ("dialogue_b", "mp4/ltx2_dialogue_512x512_24fps_7s_355kb.mp4", 3.5, 7.0),
]

OBJECT_CROPS_PER_FRAME = 8
DFINE_SIZE = 640
SIGLIP_SIZE = 224


def r6(v: float) -> float:
    return float(f"{float(v):.6g}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save_f32(name: str, values: np.ndarray) -> str:
    data = np.ascontiguousarray(values, dtype="<f4").tobytes()
    (BIN_DIR / f"{name}.f32").write_bytes(data)
    return sha256(data)


def file_sha(path: Path) -> str:
    return sha256(path.read_bytes())


def ffmpeg_frames(src: Path, start: float, end: float | None, out_dir: Path, prefix: str) -> list[Path]:
    vf = (
        f"fps={STREAM_FPS},scale={STREAM_W}:{STREAM_H}:force_original_aspect_ratio=decrease:flags=bilinear,"
        f"pad={STREAM_W}:{STREAM_H}:(ow-iw)/2:(oh-ih)/2:black"
    )
    args = ["ffmpeg", "-loglevel", "error", "-y"]
    if end is None:
        raise ValueError("end is required")
    if src.suffix == ".jpg":
        args += ["-loop", "1", "-t", f"{end}", "-i", str(src)]
    else:
        args += ["-ss", f"{start}", "-to", f"{end}", "-i", str(src)]
    args += ["-vf", vf, "-pix_fmt", "rgb24", str(out_dir / f"{prefix}_%02d.png")]
    subprocess.run(args, check=True)
    return sorted(out_dir.glob(f"{prefix}_*.png"))


def load_inputs() -> list[dict[str, Any]]:
    FRAMES_DIR.mkdir(parents=True, exist_ok=True)
    tmp = LAB_DIR / "work" / "stream-png"
    tmp.mkdir(parents=True, exist_ok=True)
    for old in tmp.glob("*.png"):
        old.unlink()

    inputs: list[dict[str, Any]] = []

    for name, rel in STILLS:
        rgb = cv2.cvtColor(cv2.imread(str(ASSETS / rel)), cv2.COLOR_BGR2RGB)
        inputs.append({"name": name, "group": "still", "source": rel, "rgb": rgb})

    t = 0.0
    for prefix, rel, start, end in STREAM:
        pngs = ffmpeg_frames(ASSETS / rel, start or 0.0, end if start is not None else end, tmp, prefix)
        for i, png in enumerate(pngs):
            rgb = cv2.cvtColor(cv2.imread(str(png)), cv2.COLOR_BGR2RGB)
            inputs.append({
                "name": png.stem,
                "group": "stream",
                "source": rel,
                "segment": prefix,
                "t": round(t, 3),
                "rgb": rgb,
            })
            t += 1.0 / STREAM_FPS
            del i

    for item in inputs:
        rgb = np.ascontiguousarray(item["rgb"])
        data = rgb.tobytes()
        (FRAMES_DIR / f"{item['name']}.rgb").write_bytes(data)
        item["width"] = int(rgb.shape[1])
        item["height"] = int(rgb.shape[0])
        item["rgb_sha256"] = sha256(data)

    return inputs


def face_json(rows: np.ndarray | list[Any], width: int, height: int) -> list[dict[str, Any]]:
    out = []
    for f in rows:
        out.append({
            "bbox": [r6(f[0] / width), r6(f[1] / height), r6((f[0] + f[2]) / width), r6((f[1] + f[3]) / height)],
            "score": r6(f[14]),
            "keypoints": [[r6(f[4 + 2 * k] / width), r6(f[5 + 2 * k] / height)] for k in range(5)],
            # full float32 precision, in pixels: what the alignment starts from
            "keypoints_px": [[float(f[4 + 2 * k]), float(f[5 + 2 * k])] for k in range(5)],
        })
    return out


def kiarina_face_json(faces: list[Any]) -> list[dict[str, Any]]:
    return [{
        "bbox": [r6(v) for v in f.bbox],
        "score": r6(f.score),
        "keypoints": [[r6(x), r6(y)] for x, y in f.keypoints],
    } for f in faces]


def l2(v: np.ndarray) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32).reshape(-1)
    return v / np.linalg.norm(v)


def cos(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(l2(a), l2(b)))


class RefModels:
    def __init__(self, cache: Path) -> None:
        self.yunet = YuNetOrt(str(YUNET_ORT))
        self.sface = ort.InferenceSession(str(cache / "sface" / "face_recognition_sface_2021dec.onnx"))
        self.dfine = ort.InferenceSession(str(cache / "dfine" / "model.onnx"))
        self.siglip = ort.InferenceSession(str(cache / "siglip2" / "vision_model_int8.onnx"))
        config = json.loads((cache / "dfine" / "config.json").read_text())
        self.labels = [config["id2label"][str(i)] for i in range(len(config["id2label"]))]

    def sface_embed(self, aligned_rgb: np.ndarray) -> np.ndarray:
        x = aligned_rgb.astype(np.float32).transpose(2, 0, 1)[None]
        return l2(self.sface.run(None, {"data": x})[0])

    def dfine_input(self, rgb: np.ndarray) -> np.ndarray:
        resized = resize_linear(rgb, DFINE_SIZE, DFINE_SIZE)
        return np.ascontiguousarray((resized.astype(np.float32) / 255.0).transpose(2, 0, 1)[None])

    def dfine_detect(self, rgb: np.ndarray, threshold: float = 0.5) -> tuple[np.ndarray, list[dict[str, Any]]]:
        x = self.dfine_input(rgb)
        logits, boxes = self.dfine.run(["logits", "pred_boxes"], {"pixel_values": x})
        logits = logits.reshape(-1, logits.shape[-1])
        boxes = boxes.reshape(-1, 4)
        scores = 1.0 / (1.0 + np.exp(-logits))
        ids = scores.argmax(axis=1)
        best = scores.max(axis=1)
        out = []
        for cid, box, score in zip(ids, boxes, best, strict=True):
            if score < threshold:
                continue
            cx, cy, w, h = (float(v) for v in box)
            out.append({
                "bbox": [r6(cx - w / 2), r6(cy - h / 2), r6(cx + w / 2), r6(cy + h / 2)],
                "score": r6(score),
                "label": self.labels[int(cid)],
            })
        return x, out

    def siglip_input(self, rgb: np.ndarray) -> np.ndarray:
        resized = resize_linear(rgb, SIGLIP_SIZE, SIGLIP_SIZE)
        image = (resized.astype(np.float32) / 255.0 - 0.5) / 0.5
        return np.ascontiguousarray(image.transpose(2, 0, 1)[None], dtype=np.float32)

    def siglip_embed(self, rgb: np.ndarray) -> np.ndarray:
        x = self.siglip_input(rgb)
        return l2(self.siglip.run(["pooler_output"], {"pixel_values": x})[0])


def crop(rgb: np.ndarray, bbox: list[float]) -> np.ndarray:
    """Same rounding and clamping as kiarina's crop_objects."""
    h, w = rgb.shape[:2]
    x1, y1, x2, y2 = (
        max(0, min(round(bbox[0] * w), w)),
        max(0, min(round(bbox[1] * h), h)),
        max(0, min(round(bbox[2] * w), w)),
        max(0, min(round(bbox[3] * h), h)),
    )
    x1, x2 = min(x1, x2), max(x1, x2)
    y1, y2 = min(y1, y2), max(y1, y2)
    return np.ascontiguousarray(rgb[y1:y2, x1:x2])


def top_objects(objects: list[dict[str, Any]], n: int) -> list[int]:
    order = sorted(range(len(objects)), key=lambda i: -objects[i]["score"])
    return order[:n]


async def run_frame(item: dict[str, Any], ref: RefModels, rc: RunContext, warp_stats: list[float]) -> dict[str, Any]:
    name = item["name"]
    rgb = item["rgb"]
    h, w = rgb.shape[:2]
    out: dict[str, Any] = {k: item[k] for k in ("name", "group", "source", "width", "height", "rgb_sha256")}
    for k in ("segment", "t"):
        if k in item:
            out[k] = item[k]

    # ---- faces
    blob, raw = ref.yunet.raw(rgb)
    ref_faces = ref.yunet.detect(rgb)
    k_faces = await detect_faces(rgb, run_context=rc)
    k_aligned = crop_align_faces(rgb, k_faces, 112)
    faces_ref = face_json(ref_faces, w, h)
    face_entries = []
    for i, f in enumerate(ref_faces):
        src = f[4:14].reshape(5, 2).astype(np.float64)
        m = _umeyama(src, _ARCFACE_DST)
        aligned = warp_affine(rgb, m, 112, 112)
        cv_aligned = cv2.warpAffine(rgb, m, (112, 112))
        warp_stats.append(float((aligned != cv_aligned).mean()))
        emb = ref.sface_embed(aligned)
        entry = {
            "aligned_sha256": sha256(aligned.tobytes()),
            "embedding_sha256": save_f32(f"{name}.face{i}", emb),
        }
        if i < len(k_aligned):
            k_emb = np.asarray(
                (await embed_image(k_aligned[i], image_embedding_options={"image_embedding_model": "face"}, run_context=rc)).vector,
                np.float32,
            )
            entry["cos_ref_kiarina"] = r6(cos(emb, k_emb))
            entry["aligned_max_diff_kiarina"] = int(np.abs(aligned.astype(int) - k_aligned[i].astype(int)).max())
        face_entries.append(entry)
    out["faces"] = {
        "blob_shape": list(blob.shape),
        "blob_sha256": sha256(blob.tobytes()),
        "raw_sum": {k: r6(float(np.asarray(v, np.float64).sum())) for k, v in raw.items()},
        "ref": faces_ref,
        "kiarina": kiarina_face_json(k_faces),
        "embeddings": face_entries,
    }

    # ---- objects
    dfine_x, objects_ref = ref.dfine_detect(rgb)
    k_objects = await detect_objects(rgb, image_detection_options={"image_detection_model": "object"}, run_context=rc)
    chosen = top_objects(objects_ref, OBJECT_CROPS_PER_FRAME)
    object_entries = []
    k_crops = crop_objects(rgb, k_objects)
    for rank, i in enumerate(chosen):
        c = crop(rgb, objects_ref[i]["bbox"])
        if c.shape[0] == 0 or c.shape[1] == 0:
            continue
        sx = ref.siglip_input(c)
        emb = ref.siglip_embed(c)
        entry = {
            "index": i,
            "crop_shape": list(c.shape),
            "crop_sha256": sha256(c.tobytes()),
            "input_sha256": sha256(sx.tobytes()),
            "embedding_sha256": save_f32(f"{name}.object{rank}", emb),
        }
        if i < len(k_crops) and len(k_objects) == len(objects_ref):
            k_emb = np.asarray(
                (await embed_image(k_crops[i].pixels, image_embedding_options={"image_embedding_model": "object"}, run_context=rc)).vector,
                np.float32,
            )
            entry["cos_ref_kiarina"] = r6(cos(emb, k_emb))
        object_entries.append(entry)
    out["objects"] = {
        "input_sha256": sha256(dfine_x.tobytes()),
        "ref": objects_ref,
        "kiarina": [{"bbox": [r6(v) for v in o.bbox], "score": r6(o.score), "label": o.label} for o in k_objects],
        "embeddings": object_entries,
    }

    # ---- whole frame (scene)
    sx = ref.siglip_input(rgb)
    scene = ref.siglip_embed(rgb)
    k_scene = np.asarray(
        (await embed_image(rgb, image_embedding_options={"image_embedding_model": "object"}, run_context=rc)).vector,
        np.float32,
    )
    out["scene"] = {
        "input_sha256": sha256(sx.tobytes()),
        "embedding_sha256": save_f32(f"{name}.scene", scene),
        "cos_ref_kiarina": r6(cos(scene, k_scene)),
    }
    return out


async def main() -> None:
    configure_app("flutter-realtime-image-analysis-fixtures", "labs")
    rc = RunContext()
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)

    inputs = load_inputs()

    # Let kiarina download its models before the ref sessions open them.
    probe = inputs[0]["rgb"]
    faces = await detect_faces(probe, run_context=rc)
    await embed_image(crop_align_faces(probe, faces, 112)[0], image_embedding_options={"image_embedding_model": "face"}, run_context=rc)
    await detect_objects(probe, image_detection_options={"image_detection_model": "object"}, run_context=rc)
    await embed_image(probe, image_embedding_options={"image_embedding_model": "object"}, run_context=rc)

    cache = Path(os.environ["KIARINA_UTILS_APP_USER_CACHE_DIR"]) / "models"
    if not YUNET_ORT.exists():
        sys.exit("missing models/yunet/yunet_2023mar_dequantized.onnx: run tools/convert_yunet.py")
    ref = RefModels(cache)

    warp_stats: list[float] = []
    frames = []
    for item in inputs:
        frames.append(await run_frame(item, ref, rc, warp_stats))
        print(item["name"], len(frames[-1]["faces"]["ref"]), "faces", len(frames[-1]["objects"]["ref"]), "objects", flush=True)

    (FIXTURES_DIR / "input.json").write_text(json.dumps({
        "stills": [{k: i[k] for k in ("name", "source", "width", "height", "rgb_sha256")} for i in inputs if i["group"] == "still"],
        "stream": {
            "width": STREAM_W,
            "height": STREAM_H,
            "fps": STREAM_FPS,
            "segments": [{"name": n, "source": s, "start": a, "end": b} for n, s, a, b in STREAM],
            "frames": [{k: i[k] for k in ("name", "segment", "t", "rgb_sha256")} for i in inputs if i["group"] == "stream"],
        },
        "frame_format": "RGB24, row-major, no padding (work/frames/<name>.rgb)",
        "models": {
            "yunet_kiarina": {"file": "face_detection_yunet_2023mar_int8bq.onnx", "sha256": file_sha(cache / "yunet" / "face_detection_yunet_2023mar_int8bq.onnx")},
            "yunet_ort": {"file": YUNET_ORT.name, "sha256": file_sha(YUNET_ORT)},
            "sface": {"file": "face_recognition_sface_2021dec.onnx", "sha256": file_sha(cache / "sface" / "face_recognition_sface_2021dec.onnx")},
            "dfine": {"file": "model.onnx", "sha256": file_sha(cache / "dfine" / "model.onnx")},
            "dfine_config": {"file": "config.json", "sha256": file_sha(cache / "dfine" / "config.json")},
            "siglip2": {"file": "vision_model_int8.onnx", "sha256": file_sha(cache / "siglip2" / "vision_model_int8.onnx")},
        },
        "labels": ref.labels,
        "warp_vs_cv2_mismatch": {"mean": r6(float(np.mean(warp_stats))) if warp_stats else None, "max": r6(max(warp_stats)) if warp_stats else None},
        "versions": {"opencv": cv2.__version__, "onnxruntime": ort.__version__, "numpy": np.__version__},
    }, indent=1, ensure_ascii=False) + "\n")
    (FIXTURES_DIR / "frames.json").write_text(json.dumps(frames, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    asyncio.run(main())
