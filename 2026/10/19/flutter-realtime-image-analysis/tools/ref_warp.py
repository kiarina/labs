"""Face alignment warp: bilinear in float64, rounded half to even, 0 outside.

This is what the Dart port computes. On the Mac that made the fixtures,
cv2.warpAffine (OpenCV 5.0.0 with the KleidiCV HAL) agrees with it on about
99.96 % of the bytes and never by more than 1 (make_fixtures.py records the
numbers); OpenCV's generic fixed-point path (1/32 pixel positions) differs
from both by up to 4 on sharp edges.
"""

import numpy as np


def invert_affine(m: np.ndarray) -> np.ndarray:
    m = np.asarray(m, dtype=np.float64)
    d = m[0, 0] * m[1, 1] - m[0, 1] * m[1, 0]
    d = 1.0 / d if d != 0 else 0.0
    a11, a22 = m[1, 1] * d, m[0, 0] * d
    a12, a21 = -m[0, 1] * d, -m[1, 0] * d
    b1 = -a11 * m[0, 2] - a12 * m[1, 2]
    b2 = -a21 * m[0, 2] - a22 * m[1, 2]
    return np.array([[a11, a12, b1], [a21, a22, b2]], dtype=np.float64)


def warp_affine(img: np.ndarray, m: np.ndarray, dw: int, dh: int) -> np.ndarray:
    """img: HxWxC uint8; m: 2x3 matrix mapping source to destination."""
    sh, sw = img.shape[:2]
    im = invert_affine(m)
    ys, xs = np.mgrid[0:dh, 0:dw].astype(np.float64)
    sx = im[0, 0] * xs + im[0, 1] * ys + im[0, 2]
    sy = im[1, 0] * xs + im[1, 1] * ys + im[1, 2]
    x0 = np.floor(sx).astype(np.int64)
    y0 = np.floor(sy).astype(np.int64)
    fx = sx - x0
    fy = sy - y0
    src = img.astype(np.float64)
    acc = np.zeros((dh, dw, img.shape[2]), np.float64)
    for dy, dx, w in ((0, 0, (1 - fy) * (1 - fx)), (0, 1, (1 - fy) * fx), (1, 0, fy * (1 - fx)), (1, 1, fy * fx)):
        px, py = x0 + dx, y0 + dy
        ok = (px >= 0) & (px < sw) & (py >= 0) & (py < sh)
        v = np.zeros_like(acc)
        v[ok] = src[py[ok], px[ok]]
        acc += v * w[..., None]
    return np.clip(np.rint(acc), 0, 255).astype(np.uint8)
