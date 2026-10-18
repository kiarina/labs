"""cv2.resize(INTER_LINEAR) on uint8 images, written out step by step.

OpenCV resizes 8-bit images with 11-bit fixed-point weights; this file
spells that arithmetic out so the Dart port can follow it and make_fixtures.py
can show it is bit-identical to cv2 for the sizes the lab uses.
"""

import math

import numpy as np

COEF_BITS = 11
COEF_SCALE = 1 << COEF_BITS


def _saturate_short(v: float) -> int:
    return int(max(-32768, min(32767, round(v))))  # cvRound: round half to even


def _coeffs(src: int, dst: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    scale = src / dst
    xofs = np.zeros(dst, np.int64)
    a0 = np.zeros(dst, np.int64)
    a1 = np.zeros(dst, np.int64)
    for d in range(dst):
        f = (d + 0.5) * scale - 0.5
        s = math.floor(f)
        f -= s
        if s < 0:
            f, s = 0.0, 0
        if s >= src - 1:
            f, s = 0.0, src - 1
        xofs[d] = s
        a0[d] = _saturate_short((1.0 - f) * COEF_SCALE)
        a1[d] = _saturate_short(f * COEF_SCALE)
    return xofs, a0, a1


def _area_2x(img: np.ndarray, dw: int, dh: int) -> np.ndarray:
    x = img[: dh * 2, : dw * 2].astype(np.int64)
    s = x[0::2, 0::2] + x[0::2, 1::2] + x[1::2, 0::2] + x[1::2, 1::2]
    return ((s + 2) >> 2).astype(np.uint8)


def resize_linear(img: np.ndarray, dw: int, dh: int) -> np.ndarray:
    sh, sw = img.shape[:2]
    if sw == dw * 2 and sh == dh * 2:
        return _area_2x(img, dw, dh)
    xofs, a0, a1 = _coeffs(sw, dw)
    yofs, b0, b1 = _coeffs(sh, dh)
    x = img.astype(np.int64)
    x1 = np.minimum(xofs + 1, sw - 1)
    rows = x[:, xofs] * a0[None, :, None] + x[:, x1] * a1[None, :, None]  # (sh, dw, c)
    y1 = np.minimum(yofs + 1, sh - 1)
    s0 = rows[yofs]
    s1 = rows[y1]
    v = (((b0[:, None, None] * (s0 >> 4)) >> 16) + ((b1[:, None, None] * (s1 >> 4)) >> 16) + 2) >> 2
    return np.clip(v, 0, 255).astype(np.uint8)
