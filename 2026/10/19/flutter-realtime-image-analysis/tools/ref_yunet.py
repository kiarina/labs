"""YuNet on ONNX Runtime, decoded the way OpenCV's FaceDetectorYN does.

The Dart port follows this file; make_fixtures.py checks it against
kiarina's OpenCV path so the two can be compared stage by stage.
"""

import math

import numpy as np
import onnxruntime as ort

STRIDES = (8, 16, 32)


def pad_size(n: int) -> int:
    return ((n - 1) // 32 + 1) * 32


def make_blob(rgb: np.ndarray) -> np.ndarray:
    """BGR, 0..255 float32, zero-padded at the right and bottom, NCHW."""
    h, w = rgb.shape[:2]
    blob = np.zeros((1, 3, pad_size(h), pad_size(w)), dtype=np.float32)
    blob[0, :, :h, :w] = rgb[..., ::-1].transpose(2, 0, 1)
    return blob


def decode(outputs: dict[str, np.ndarray], pad_h: int, pad_w: int) -> np.ndarray:
    """Rows of [x, y, w, h, 5 x (kx, ky), score] in input pixels, float32."""
    rows = []
    for stride in STRIDES:
        cols = pad_w // stride
        n_rows = pad_h // stride
        cls = outputs[f"cls_{stride}"].reshape(-1)
        obj = outputs[f"obj_{stride}"].reshape(-1)
        bbox = outputs[f"bbox_{stride}"].reshape(-1, 4)
        kps = outputs[f"kps_{stride}"].reshape(-1, 10)
        for r in range(n_rows):
            for c in range(cols):
                i = r * cols + c
                cls_s = min(max(float(cls[i]), 0.0), 1.0)
                obj_s = min(max(float(obj[i]), 0.0), 1.0)
                score = np.float32(math.sqrt(np.float32(cls_s) * np.float32(obj_s)))
                cx = (c + bbox[i, 0]) * stride
                cy = (r + bbox[i, 1]) * stride
                bw = np.exp(bbox[i, 2]) * stride
                bh = np.exp(bbox[i, 3]) * stride
                row = [cx - bw / 2, cy - bh / 2, bw, bh]
                for n in range(5):
                    row += [(kps[i, 2 * n] + c) * stride, (kps[i, 2 * n + 1] + r) * stride]
                row.append(score)
                rows.append(row)
    return np.asarray(rows, dtype=np.float32)


def iou_int(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> float:
    ax2, ay2 = a[0] + a[2], a[1] + a[3]
    bx2, by2 = b[0] + b[2], b[1] + b[3]
    iw = min(ax2, bx2) - max(a[0], b[0])
    ih = min(ay2, by2) - max(a[1], b[1])
    inter = iw * ih if iw > 0 and ih > 0 else 0
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


def nms(faces: np.ndarray, score_threshold: float, nms_threshold: float, top_k: int) -> np.ndarray:
    boxes = [tuple(int(v) for v in f[:4]) for f in faces]
    scores = faces[:, 14]
    order = [i for i in np.argsort(-scores, kind="stable") if scores[i] > score_threshold][:top_k]
    keep: list[int] = []
    for i in order:
        if all(iou_int(boxes[i], boxes[k]) <= nms_threshold for k in keep):
            keep.append(int(i))
    return faces[keep] if keep else np.zeros((0, 15), np.float32)


class YuNetOrt:
    def __init__(self, model_path: str, score_threshold: float = 0.9, nms_threshold: float = 0.3, top_k: int = 5000):
        self.session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
        self.names = [o.name for o in self.session.get_outputs()]
        self.score_threshold = score_threshold
        self.nms_threshold = nms_threshold
        self.top_k = top_k

    def raw(self, rgb: np.ndarray) -> tuple[np.ndarray, dict[str, np.ndarray]]:
        blob = make_blob(rgb)
        outputs = dict(zip(self.names, self.session.run(None, {"input": blob}), strict=True))
        return blob, outputs

    def detect(self, rgb: np.ndarray) -> np.ndarray:
        blob, outputs = self.raw(rgb)
        faces = decode(outputs, blob.shape[2], blob.shape[3])
        return nms(faces, self.score_threshold, self.nms_threshold, self.top_k)
