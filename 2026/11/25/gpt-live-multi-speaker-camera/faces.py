"""Face identification for the lab: OpenCV YuNet (detection) + SFace (128-d embedding, cosine).

Enrollment keeps either one centroid per person (mode 'centroid', option (a)) or every enrollment embedding
(mode 'gallery', option (b): the best match over a person's photos).
"""
from pathlib import Path

import cv2
import numpy as np

MODELS = Path(__file__).parent / 'work' / 'models-face'


class Faces:
    def __init__(self, mode='gallery', threshold=0.363, min_score=0.7):
        self.det = cv2.FaceDetectorYN.create(str(MODELS / 'face_detection_yunet_2023mar.onnx'), '', (320, 320), min_score, 0.3, 5000)
        self.rec = cv2.FaceRecognizerSF.create(str(MODELS / 'face_recognition_sface_2021dec.onnx'), '')
        self.mode, self.threshold, self.bank = mode, threshold, {}

    def detect(self, img):
        h, w = img.shape[:2]
        self.det.setInputSize((w, h))
        _, found = self.det.detect(img)
        return [] if found is None else list(found)

    def embed(self, img, face):
        v = self.rec.feature(self.rec.alignCrop(img, face)).reshape(-1).astype(np.float32)
        return v / (np.linalg.norm(v) + 1e-9)

    def enroll(self, name, paths):
        vs = []
        for p in paths:
            img = cv2.imread(str(p))
            found = sorted(self.detect(img), key=lambda f: -f[2] * f[3])  # the largest face
            if found:
                vs.append(self.embed(img, found[0]))
        if not vs:
            raise ValueError(f'no face in the enrollment photos of {name}')
        if self.mode == 'centroid':
            c = np.mean(vs, axis=0)
            self.bank[name] = [c / np.linalg.norm(c)]
        else:
            self.bank[name] = vs
        return len(vs)

    def identify(self, img):
        """Faces left to right: [{'name' (None if unknown), 'score', 'scores', 'box', 'where'}]."""
        h, w = img.shape[:2]
        out = []
        for f in sorted(self.detect(img), key=lambda f: f[0]):
            e = self.embed(img, f)
            scores = {n: float(max(e @ v for v in vs)) for n, vs in self.bank.items()}
            best = max(scores, key=scores.get)
            cx = (f[0] + f[2] / 2) / w
            where = '左' if cx < 1 / 3 else ('真ん中' if cx < 2 / 3 else '右')
            if f[3] / h < 0.1:  # a small face: far from the camera
                where += 'の奥'
            out.append({'name': best if scores[best] >= self.threshold else None, 'score': round(scores[best], 3),
                        'scores': {k: round(v, 3) for k, v in scores.items()}, 'box': [int(x) for x in f[:4]], 'where': where,
                        'size': round(float(f[3]) / h, 3)})
        return out


def annotate(img, faces):
    """Draw boxes and names (ASCII-free labels drawn with PIL by the caller)."""
    img = img.copy()
    for f in faces:
        x, y, bw, bh = f['box']
        cv2.rectangle(img, (x, y), (x + bw, y + bh), (0, 255, 0) if f['name'] else (0, 165, 255), 3)
    return img
