"""x6 preview on a pale background + 4-direction walk GIF for a 96x128 sheet."""
import sys
from PIL import Image

src, prefix = sys.argv[1], sys.argv[2]
BG = (0xDC, 0xEC, 0xD8, 255)
img = Image.open(src).convert("RGBA")
bg = Image.new("RGBA", img.size, BG)
bg.alpha_composite(img)
bg.resize((96 * 6, 128 * 6), Image.NEAREST).save(f"{prefix}_x6.png")
frames = []
for t in range(16):
    c = [0, 1, 2, 1][t % 4]
    f = Image.new("RGBA", (128, 32), BG)
    for d in range(4):
        f.alpha_composite(img.crop((c * 32, d * 32, c * 32 + 32, d * 32 + 32)), (d * 32, 0))
    frames.append(f.resize((128 * 6, 32 * 6), Image.NEAREST).convert("RGB"))
frames[0].save(f"{prefix}_walk.gif", save_all=True, append_images=frames[1:], duration=180, loop=0)
