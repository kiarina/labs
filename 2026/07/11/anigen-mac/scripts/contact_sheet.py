from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT.parents[3] / "tests" / "assets" / "jpg"
FONT = ImageFont.load_default(size=22)


def tile(path: Path, label: str) -> Image.Image:
    if not path.is_file():
        canvas = Image.new("RGB", (540, 570), "#f3f4f6")
        draw = ImageDraw.Draw(canvas)
        draw.text((16, 10), label, fill="#111827", font=FONT)
        draw.multiline_text(
            (50, 240),
            "Not generated\nInference produced zero faces",
            fill="#991b1b",
            font=FONT,
            spacing=10,
            align="center",
        )
        return canvas
    image = Image.open(path).convert("RGB")
    image.thumbnail((512, 512), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (540, 570), "white")
    x = (canvas.width - image.width) // 2
    y = 40 + (512 - image.height) // 2
    canvas.paste(image, (x, y))
    draw = ImageDraw.Draw(canvas)
    draw.text((16, 10), label, fill="#111827", font=FONT)
    return canvas


for name, input_name in (
    ("miineko1", "miineko1_1254x1254_159kb.jpg"),
    ("miineko2", "miineko2_1086x1448_219kb.jpg"),
):
    paths = (
        (ASSETS / input_name, "Input"),
        (ROOT / "results" / name / "processed_image.png", "Processed input"),
        (ROOT / "preview" / "renders" / f"{name}-mesh.png", "Rigged mesh"),
        (ROOT / "preview" / "renders" / f"{name}-skeleton.png", "Skeleton"),
    )
    sheet = Image.new("RGB", (1080, 1140), "#e5e7eb")
    for index, item in enumerate(paths):
        image = tile(*item)
        sheet.paste(image, ((index % 2) * 540, (index // 2) * 570))
    output = ROOT / "preview" / f"{name}-comparison.jpg"
    output.parent.mkdir(exist_ok=True)
    sheet.save(output, quality=82, optimize=True, progressive=True)
    print(output.relative_to(ROOT))
