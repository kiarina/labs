"""Animation review: filmstrip (play order 0,1,2,1) with guides, onion skins, and per-frame metrics."""
import sys

from PIL import Image, ImageDraw

SRC = sys.argv[1]
OUT = sys.argv[2]
SC = 8
ORDER = [0, 1, 2, 1]
DIRS = ["down", "left", "right", "up"]

img = Image.open(SRC).convert("RGBA")


def cell(c, d):
    return img.crop((c * 32, d * 32, c * 32 + 32, d * 32 + 32))


def mask(im):
    return {(x, y) for y in range(32) for x in range(32) if im.getpixel((x, y))[3] > 0}


def metrics(im):
    m = mask(im)
    xs = [x for x, _ in m]
    ys = [y for _, y in m]
    # body = largest-color region approximated by rows 6..25 width
    return {
        "bbox": (min(xs), min(ys), max(xs), max(ys)),
        "cx": round(sum(xs) / len(xs), 2),
        "cy": round(sum(ys) / len(ys), 2),
        "ground": max(ys),
        "n": len(m),
    }


W = (len(ORDER) + 3) * 34 * SC
H = 4 * 34 * SC
sheet = Image.new("RGBA", (W, H), (0xDC, 0xEC, 0xD8, 255))
dr = ImageDraw.Draw(sheet)
for d in range(4):
    oy = d * 34 * SC
    print(f"== {DIRS[d]}")
    for c in range(3):
        print(f"  frame{c}: {metrics(cell(c, d))}")
    # filmstrip
    for i, c in enumerate(ORDER):
        ox = i * 34 * SC
        sheet.alpha_composite(cell(c, d).resize((32 * SC, 32 * SC), Image.NEAREST), (ox, oy))
        g = metrics(cell(1, d))["ground"]
        dr.line([(ox, oy + (g + 1) * SC), (ox + 32 * SC, oy + (g + 1) * SC)], fill=(0, 120, 255), width=2)
        dr.line([(ox + 16 * SC, oy), (ox + 16 * SC, oy + 32 * SC)], fill=(0, 120, 255), width=1)
    # onion skins: 0->1, 1->2, 0 vs 2
    for j, (a, b) in enumerate([(0, 1), (1, 2), (0, 2)]):
        ox = (len(ORDER) + j) * 34 * SC
        ma, mb = mask(cell(a, d)), mask(cell(b, d))
        on = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        for (x, y) in ma | mb:
            if (x, y) in ma and (x, y) in mb:
                same = cell(a, d).getpixel((x, y)) == cell(b, d).getpixel((x, y))
                on.putpixel((x, y), (150, 150, 150, 255) if same else (200, 0, 200, 255))
            elif (x, y) in ma:
                on.putpixel((x, y), (255, 60, 60, 255))
            else:
                on.putpixel((x, y), (40, 160, 255, 255))
        sheet.alpha_composite(on.resize((32 * SC, 32 * SC), Image.NEAREST), (ox, oy))
sheet.save(OUT)
