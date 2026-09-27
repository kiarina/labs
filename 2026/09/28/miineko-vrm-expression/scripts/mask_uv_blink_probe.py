"""Paint a closed-eye texture in the original UV layout of the full face mask.

This tests a real texture switch on the conformal mask. The source head and
original BaseColor remain visible at neutral; no separate eyelid cap is used.
"""

from pathlib import Path

import bpy
import numpy as np


out = Path(__file__).resolve().parents[1] / "artifacts"
bpy.ops.wm.open_mainfile(filepath=str(out / "mask-probe.blend"))
mask = bpy.data.objects["Miineko_Face_Mask_Neutral"]
material = mask.material_slots[0].material
texture_node = next(
    node for node in material.node_tree.nodes
    if node.type == "TEX_IMAGE" and node.image and "BaseColor" in node.image.filepath
)
source_image = texture_node.image
width, height = source_image.size
if (width, height) != (4096, 4096):
    raise RuntimeError(f"Unexpected BaseColor size: {width}x{height}")

# Blender's image pixels and UV coordinates both use bottom-left origins.
pixels = np.empty(width * height * 4, dtype=np.float32)
source_image.pixels.foreach_get(pixels)
pixels = pixels.reshape((height, width, 4))
closed = pixels.copy()
# Sampled from a forehead UV pixel of the original Tripo BaseColor atlas.
skin_color = np.array((0.9215687, 0.00392157, 0.53333336), dtype=np.float32)
ink_color = np.array((0.004, 0.002, 0.004), dtype=np.float32)

mesh = mask.data
uv = mesh.uv_layers.get("UVMap") or mesh.uv_layers[0]
mesh.calc_loop_triangles()
painted = 0
for tri in mesh.loop_triangles:
    points = np.array([mesh.vertices[mesh.loops[i].vertex_index].co[:] for i in tri.loops])
    if not (np.any((np.abs(points[:, 0]) > 0.015) & (np.abs(points[:, 0]) < 0.29))
            and np.any((points[:, 2] > 0.48) & (points[:, 2] < 0.76))):
        continue
    coords = np.array([uv.data[i].uv[:] for i in tri.loops])
    coords[:, 0] *= width - 1
    coords[:, 1] *= height - 1
    x0 = max(0, int(np.floor(coords[:, 0].min())))
    x1 = min(width, int(np.ceil(coords[:, 0].max())) + 1)
    y0 = max(0, int(np.floor(coords[:, 1].min())))
    y1 = min(height, int(np.ceil(coords[:, 1].max())) + 1)
    if x1 <= x0 or y1 <= y0:
        continue
    a, b, c = coords
    denominator = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
    if abs(denominator) < 1e-8:
        continue
    yy, xx = np.mgrid[y0:y1, x0:x1]
    xx = xx + 0.5
    yy = yy + 0.5
    wa = ((b[1] - c[1]) * (xx - c[0]) + (c[0] - b[0]) * (yy - c[1])) / denominator
    wb = ((c[1] - a[1]) * (xx - c[0]) + (a[0] - c[0]) * (yy - c[1])) / denominator
    wc = 1 - wa - wb
    inside = (wa >= -1e-5) & (wb >= -1e-5) & (wc >= -1e-5)
    if not inside.any():
        continue
    px = wa * points[0, 0] + wb * points[1, 0] + wc * points[2, 0]
    pz = wa * points[0, 2] + wb * points[1, 2] + wc * points[2, 2]
    r = np.minimum(
        np.sqrt(((px - 0.15) / 0.125) ** 2 + ((pz - 0.62) / 0.12) ** 2),
        np.sqrt(((px + 0.15) / 0.125) ** 2 + ((pz - 0.62) / 0.12) ** 2),
    )
    blend = np.clip((1.02 - r) / 0.10, 0, 1)
    blend = blend * blend * (3 - 2 * blend)
    blend *= inside
    if not (blend > 0).any():
        continue
    # A curved line is painted into the texture, not placed as geometry.
    eye_x = np.where(px >= 0, px - 0.15, px + 0.15)
    curve_z = 0.62 + 0.008 * (1 - (eye_x / 0.075) ** 2)
    line = (np.abs(eye_x) < 0.076) & (np.abs(pz - curve_z) < 0.0035)
    target = np.where(line[..., None], ink_color, skin_color)
    region = closed[y0:y1, x0:x1, :3]
    region[:] = region * (1 - blend[..., None]) + target * blend[..., None]
    painted += int((blend > 0).sum())

closed_image = bpy.data.images.new("Miineko_UV_Blink", width=width, height=height, alpha=True)
closed_image.pixels.foreach_set(closed.ravel())
closed_image.filepath_raw = str(out / "mask-uv-blink-texture.png")
closed_image.file_format = "PNG"
closed_image.save()
closed_material = material.copy()
closed_material.name = "Face Mask UV Blink"
closed_texture = next(
    node for node in closed_material.node_tree.nodes
    if node.type == "TEX_IMAGE" and node.image and "BaseColor" in node.image.filepath
)
closed_texture.image = closed_image
mask.data.materials.append(closed_material)


scene = bpy.context.scene
for poly in mask.data.polygons:
    poly.material_index = 0
scene.render.filepath = str(out / "mask-uv-neutral.png")
bpy.ops.render.render(write_still=True)

for poly in mask.data.polygons:
    poly.material_index = 1
scene.render.filepath = str(out / "mask-uv-blink.png")
bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(out / "mask-uv-blink-probe.blend"))
print("PAINTED_PIXELS", painted)
