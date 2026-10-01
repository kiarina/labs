"""Apple mascot (yuru-chara) walk sheet: 32x32 cells, 3 cols x 4 rows (down, left, right, up)."""
from PIL import Image

PAL = {
    "O": (0x3B, 0x1A, 0x24),  # outline / limbs / eyes
    "R": (0xE8, 0x3E, 0x3E),  # apple red
    "r": (0xB4, 0x26, 0x34),  # red shadow
    "H": (0xFF, 0x80, 0x70),  # red highlight
    "W": (0xFF, 0xFF, 0xFF),  # shine / gloves / eye highlight
    "p": (0xFF, 0xA8, 0xB0),  # blush
    "n": (0x7A, 0x4A, 0x2A),  # stem
    "G": (0x4C, 0xA8, 0x3C),  # leaf
    "L": (0x9C, 0xE0, 0x5A),  # leaf light
    "N": (0x8A, 0x52, 0x30),  # shoes
    "w": (0xB8, 0xB8, 0xCC),  # glove shade / far glove
    "D": (0x5A, 0x34, 0x20),  # far shoe
}

CX, CY, RX, RY = 15.5, 15.5, 9.9, 9.2


def blank():
    return [["."] * 32 for _ in range(32)]


def body_fill(g, back=False):
    pts = set()
    for y in range(32):
        for x in range(32):
            if ((x - CX) / RX) ** 2 + ((y - CY) / RY) ** 2 <= 1.0:
                pts.add((x, y))
    pts -= {(15, 7), (16, 7), (15, 24), (16, 24)}  # top dimple, bottom dimple
    lx = 11.0 if not back else 20.0
    for (x, y) in pts:
        d = ((x - lx) / RX) ** 2 + ((y - 11.0) / RY) ** 2
        g[y][x] = "r" if d > 1.45 else "R"
    hx = 10.5 if not back else 20.5
    for (x, y) in pts:
        if ((x - hx) / 2.6) ** 2 + ((y - 11.0) / 2.0) ** 2 <= 1.0:
            g[y][x] = "H"
    shine = [(9, 11), (9, 10), (10, 9)] if not back else [(22, 11), (22, 10), (21, 9)]
    for (x, y) in shine:
        g[y][x] = "W"


def stem_leaf(g, flip=False):
    pts = {(16, 3): "n", (16, 4): "n", (15, 5): "n", (15, 6): "n",
           (19, 2): "G", (20, 2): "G",
           (18, 3): "G", (19, 3): "L", (20, 3): "G", (21, 3): "G",
           (17, 4): "L", (18, 4): "G", (19, 4): "G", (20, 4): "G",
           (18, 5): "G"}
    for (x, y), c in pts.items():
        if flip:
            x = 31 - x
        g[y][x] = c


def auto_outline(g):
    add = []
    for y in range(32):
        for x in range(32):
            if g[y][x] != ".":
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < 32 and 0 <= ny < 32 and g[ny][nx] not in ".O":
                    add.append((x, y))
                    break
    for (x, y) in add:
        g[y][x] = "O"


def line(g, x0, y0, x1, y1, c="O"):
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx + dy
    while True:
        if 0 <= x0 < 32 and 0 <= y0 < 32 and g[y0][x0] == ".":
            g[y0][x0] = c
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


GLOVE = [".OOO.", "OWWWO", "OWWwO", ".OOO."]
SHOE = [".OOO.", "ONNNO", "OOOOO"]
SHOE_L = [".OOO.", "ONNNO", "OOOOO"]


def stamp(g, pat, x0, y0, overwrite=False):
    for dy, row in enumerate(pat):
        for dx, c in enumerate(row):
            x, y = x0 + dx, y0 + dy
            if c != "." and 0 <= x < 32 and 0 <= y < 32 and (overwrite or g[y][x] == "."):
                g[y][x] = c


GLOVE_FAR = [".OOO.", "OwwwO", "OwwwO", ".OOO."]
SHOE_FAR = [".OOO.", "ODDDO", "OOOOO"]


def line_force(g, x0, y0, x1, y1, c="O"):
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx + dy
    while True:
        if 0 <= x0 < 32 and 0 <= y0 < 32:
            g[y0][x0] = c
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def arm(g, sx, sy, gx, gy, far=False, over=False):
    """Shoulder (sx, sy) to glove top-left (gx, gy)."""
    (line_force if over else line)(g, sx, sy, gx + 2, gy + 1)
    stamp(g, GLOVE_FAR if far else GLOVE, gx, gy, overwrite=not far)


def leg(g, hx, hy, shoe_x, shoe_y, far=False):
    line(g, hx, hy, shoe_x + 2, shoe_y)
    stamp(g, SHOE_FAR if far else SHOE, shoe_x, shoe_y, overwrite=True)


def face_front(g):
    for ex in (11, 19):
        for y in (14, 15, 16):
            g[y][ex] = g[y][ex + 1] = "O"
        g[14][ex + 1] = "W"
    for x in (9, 10, 21, 22):
        g[17][x] = "p"
    for (x, y) in ((14, 17), (15, 18), (16, 18), (17, 17)):
        g[y][x] = "O"


def face_side(g):
    for y in (14, 15, 16):
        g[y][8] = g[y][9] = "O"
    g[14][9] = "W"
    g[17][11] = g[17][12] = "p"
    for (x, y) in ((7, 18), (8, 19), (9, 18)):
        g[y][x] = "O"


def bob_up(g, b):
    return g[b:] + [["."] * 32 for _ in range(b)]


def front_like(step, back=False):
    g = blank()
    body_fill(g, back)
    stem_leaf(g, flip=back)
    auto_outline(g)
    if not back:
        face_front(g)
    b = 0 if step == 1 else 1  # hop up on each step
    g = bob_up(g, b)
    # legs: lifted foot rises 2px; planted foot stays on the ground
    lsy = 25 if step == 0 else 27
    rsy = 25 if step == 2 else 27
    leg(g, 12, 25 - b, 10, lsy)
    leg(g, 19, 25 - b, 17, rsy)
    # arms swing opposite to legs (forward = slightly up)
    ly = {0: 19, 1: 18, 2: 16}[step] - b
    ry = {0: 16, 1: 18, 2: 19}[step] - b
    arm(g, 5, 17 - b, 0, ly)
    arm(g, 26, 17 - b, 27, ry)
    return g


def side(step):
    """Facing left. Near side = viewer side; far limbs are darker and drawn behind."""
    g = blank()
    body_fill(g)
    stem_leaf(g)
    auto_outline(g)
    face_side(g)
    b = 0 if step == 1 else 1
    g = bob_up(g, b)
    if step == 1:  # passing pose
        leg(g, 17, 25 - b, 14, 27, far=True)
        leg(g, 14, 25 - b, 11, 27)
        arm(g, 15, 18 - b, 12, 21 - b, over=True)
    else:
        near_fwd = step == 0
        fwd, back_ = (7, 27), (19, 26)
        nf, ff = (fwd, back_) if near_fwd else (back_, fwd)
        leg(g, 17, 25 - b, ff[0], ff[1], far=True)
        leg(g, 14, 25 - b, nf[0], nf[1])
        # far arm swings with the near leg, near arm opposite
        # near arm swings opposite to the near leg, inside the silhouette
        if near_fwd:
            arm(g, 15, 18 - b, 17, 20 - b, over=True)
        else:
            arm(g, 15, 18 - b, 8, 20 - b, over=True)
    return g


def mirror(g):
    return [r[::-1] for r in g]


def sheet():
    rows = [
        [front_like(s) for s in range(3)],
        [side(s) for s in range(3)],
        [mirror(side(s)) for s in range(3)],
        [front_like(s, back=True) for s in range(3)],
    ]
    img = Image.new("RGBA", (96, 128), (0, 0, 0, 0))
    for r, cells in enumerate(rows):
        for c, g in enumerate(cells):
            for y in range(32):
                for x in range(32):
                    if g[y][x] != ".":
                        img.putpixel((c * 32 + x, r * 32 + y), PAL[g[y][x]] + (255,))
    return img


if __name__ == "__main__":
    import sys

    sheet().save(sys.argv[1])
