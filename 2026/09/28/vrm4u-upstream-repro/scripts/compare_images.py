#!/usr/bin/env python3
"""Pixel difference between two screenshots of the same size."""

import sys

from PIL import Image, ImageChops

a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
assert a.size == b.size, (a.size, b.size)
diff = ImageChops.difference(a, b)
pixels = list(diff.getdata())
changed = sum(1 for p in pixels if max(p) > 8)
print(f"{sys.argv[1]} vs {sys.argv[2]}: size={a.size} max_channel_diff={max(max(p) for p in pixels)} "
      f"pixels_over_8={changed} ({100.0 * changed / len(pixels):.3f}%)")
