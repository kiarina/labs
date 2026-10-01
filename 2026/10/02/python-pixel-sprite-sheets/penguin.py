"""Penguin sprite design (32x32 x 3 cols x 4 rows: down, left, right, up)."""
import sys

PAL = {
    "O": (0x22, 0x20, 0x34),  # outline idx1
    "B": (0x30, 0x60, 0x82),  # body idx16
    "H": (0x63, 0x9B, 0xFF),  # highlight idx18
    "W": (0xFF, 0xFF, 0xFF),  # white idx21
    "K": (0x00, 0x00, 0x00),  # eye idx0
    "Y": (0xDF, 0x71, 0x26),  # beak/feet idx5
    "y": (0xA0, 0x4C, 0x1C),  # far foot
    "P": (0xD9, 0x57, 0x63),  # blush idx28
}


def ell(cx, cy, rx, ry):
    return {(x, y) for x in range(32) for y in range(32)
            if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0}


def outline(mask):
    return {(x, y) for (x, y) in mask
            if any((x + dx, y + dy) not in mask for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))}


def put(g, pts, c):
    for (x, y) in pts:
        if 0 <= x < 32 and 0 <= y < 32:
            g[y][x] = c


def blank():
    return [["." for _ in range(32)] for _ in range(32)]


def rect(x0, y0, x1, y1):
    return {(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}


BODY = ell(15.5, 16.0, 8.6, 12.4)


def foot1(g, fx, fy, far=False, w=4):
    c = "y" if far else "Y"
    put(g, rect(fx, fy, fx + w - 1, fy + 1), c)
    put(g, {(fx + i, fy + 2) for i in range(w)}, "O")
    put(g, {(fx - 1, fy + 1), (fx + w, fy + 1)}, "O")


def over(g, layer, dx=0, dy=0):
    for y in range(32):
        for x in range(32):
            c = layer[y][x]
            if c != "." and 0 <= x + dx < 32 and 0 <= y + dy < 32:
                g[y + dy][x + dx] = c


def flipper(layer, side_, raise_=False):
    fl = rect(4, 15, 7, 21) & ell(6.0, 18.0, 2.2, 3.6)
    if raise_:  # lifted out and up for balance
        fl = {(x - 1, y - 2) for (x, y) in fl}
    if side_:
        fl = {(31 - x, y) for (x, y) in fl}
    put(layer, fl, "B")
    put(layer, outline(fl), "O")


def front_like(step, back_view=False):
    """Waddle: weight shifts 1px onto the planted foot, the lifted side's flipper goes up."""
    g = blank()
    foot1(g, 10, 26 if step == 0 else 27)
    foot1(g, 18, 26 if step == 2 else 27)
    layer = blank()
    flipper(layer, 0, raise_=(step == 0))
    flipper(layer, 1, raise_=(step == 2))
    put(layer, BODY, "B")
    put(layer, outline(BODY), "O")
    if back_view:
        put(layer, {(11, 6), (12, 6), (10, 7)}, "H")
        put(layer, {(15, 28), (16, 28), (15, 27), (16, 27)}, "O")  # tail
    else:
        face = (ell(15.5, 13.0, 6.3, 4.6) | ell(15.5, 21.5, 5.6, 6.0)) & BODY
        face -= {(15, 8), (16, 8), (15, 9), (16, 9)}  # heart notch
        put(layer, face, "W")
        put(layer, {(11, 6), (12, 6), (10, 7)}, "H")
        for ex in (12, 18):
            put(layer, rect(ex, 11, ex + 1, 13), "K")
            put(layer, {(ex, 11)}, "W")
        put(layer, rect(14, 14, 17, 14) | rect(15, 15, 16, 15), "Y")
        put(layer, {(10, 15), (11, 15), (20, 15), (21, 15)}, "P")
    over(g, layer, dx={0: 1, 1: 0, 2: -1}[step])
    return g


def front(step):
    return front_like(step)


def back(step):
    return front_like(step, back_view=True)


def side(step):
    """Facing left. Bob 1px on steps, flipper swings opposite the near foot, far foot darker."""
    g = blank()
    b = 0 if step == 1 else 1
    if step == 1:
        foot1(g, 14, 27, far=True)
        foot1(g, 10, 27)
    else:
        near_fwd = step == 0
        fwd, back_ = (8, 27), (17, 26)
        nf, ff = (fwd, back_) if near_fwd else (back_, fwd)
        foot1(g, ff[0], ff[1], far=True)
        foot1(g, nf[0], nf[1])
    layer = blank()
    put(layer, BODY, "B")
    put(layer, outline(BODY), "O")
    face = (ell(11.5, 13.0, 4.8, 4.4) | ell(12.5, 21.5, 4.6, 6.0)) & BODY
    face -= outline(BODY)
    put(layer, face, "W")
    put(layer, {(17, 6), (18, 6), (19, 7)}, "H")
    put(layer, rect(9, 11, 10, 13), "K")
    put(layer, {(9, 11)}, "W")
    put(layer, rect(4, 14, 8, 14) | rect(5, 15, 8, 15), "Y")
    put(layer, {(3, 14), (4, 15), (4, 13), (5, 13), (6, 13), (7, 13), (5, 16), (6, 16), (7, 16)}, "O")
    put(layer, {(11, 15), (12, 15)}, "P")
    fcx = {0: 19.5, 1: 18.5, 2: 17.5}[step]
    fl = ell(fcx, 19.5, 2.2, 4.2)
    put(layer, fl, "B")
    put(layer, outline(fl), "O")
    over(g, layer, dy=-b)
    return g


def mirror(g):
    return [row[::-1] for row in g]


def frames():
    out = []
    for s in range(3):
        out.append(front(s))
    for s in range(3):
        out.append(side(s))
    for s in range(3):
        out.append(mirror(side(s)))
    for s in range(3):
        out.append(back(s))
    return out


def sheet():
    from PIL import Image

    img = Image.new("RGBA", (96, 128), (0, 0, 0, 0))
    for i, g in enumerate(frames()):
        ox, oy = (i % 3) * 32, (i // 3) * 32
        for y in range(32):
            for x in range(32):
                if g[y][x] != ".":
                    img.putpixel((ox + x, oy + y), PAL[g[y][x]] + (255,))
    return img


if __name__ == "__main__":
    sheet().save(sys.argv[1])
