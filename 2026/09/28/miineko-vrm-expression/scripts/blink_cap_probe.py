"""Test a conformal, detachable eyelid on the untouched Tripo head."""

import bmesh
import bpy
import math
from pathlib import Path
from mathutils import Vector


out = Path(__file__).resolve().parents[1] / "artifacts"
bpy.ops.wm.open_mainfile(filepath=str(out / "mask-probe.blend"))
body = next(obj for obj in bpy.data.objects if obj.type == "MESH" and obj.name != "Miineko_Face_Mask_Neutral")
face_mask = bpy.data.objects["Miineko_Face_Mask_Neutral"]
face_mask.hide_render = True
face_mask.hide_set(True)

def face_y(x, z):
    q = z - 0.64
    return (-0.286787297 - 0.000335269 * x + 0.0758551227 * q
            + 1.20671255 * x*x + 1.16455271 * q*q + 0.0002285975 * x*q)


def smooth(t):
    t = max(0, min(1, t))
    return t*t*(3-2*t)

skin = bpy.data.materials.new("Conformal Blink Skin")
skin.diffuse_color = (0.84, 0.001, 0.251, 1)
skin.use_nodes = True
principled = next(node for node in skin.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
principled.inputs["Base Color"].default_value = (0.84, 0.001, 0.251, 1)
principled.inputs["Roughness"].default_value = 0.7
skin.blend_method = "BLEND"
skin.surface_render_method = "BLENDED"
alpha_attribute = skin.node_tree.nodes.new("ShaderNodeAttribute")
alpha_attribute.attribute_name = "CapAlpha"
skin.node_tree.links.new(alpha_attribute.outputs["Alpha"], principled.inputs["Alpha"])

black = bpy.data.materials.new("Conformal Blink Line")
black.diffuse_color = (0.004, 0.002, 0.004, 1)
black.use_nodes = True
black_shader = next(node for node in black.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
black_shader.inputs["Base Color"].default_value = (0.004, 0.002, 0.004, 1)
black_shader.inputs["Roughness"].default_value = 0.7


def eyelid(side):
    center_x = side * 0.15
    cap = face_mask.copy()
    cap.data = face_mask.data.copy()
    cap.name = f"Conformal_Blink_{'L' if side > 0 else 'R'}"
    bpy.context.collection.objects.link(cap)
    cap.hide_render = False
    cap.hide_set(False)
    bm = bmesh.new()
    bm.from_mesh(cap.data)
    remove = []
    for face in bm.faces:
        p = face.calc_center_median()
        if p.y >= -0.14 or ((p.x - center_x) / 0.130) ** 2 + ((p.z - 0.62) / 0.120) ** 2 >= 1:
            remove.append(face)
    bmesh.ops.delete(bm, geom=remove, context="FACES")
    bm.to_mesh(cap.data)
    bm.free()
    cap.data.update()
    cap.data.materials.clear()
    cap.data.materials.append(skin)
    for poly in cap.data.polygons:
        poly.material_index = 0
    # The outer surface is a smooth eyelid laid over the recessed eye. It
    # meets the surrounding original head at the cap's pink boundary.
    for v in cap.data.vertices:
        v.co.y = face_y(v.co.x, v.co.z) - 0.006
    alpha_layer = cap.data.color_attributes.new(
        name="CapAlpha", type="FLOAT_COLOR", domain="CORNER"
    )
    for loop in cap.data.loops:
        p = cap.data.vertices[loop.vertex_index].co
        r = math.sqrt(((p.x-center_x)/0.130)**2+((p.z-0.62)/0.120)**2)
        alpha = 1 - smooth((r-0.84)/0.14)
        alpha_layer.data[loop.index].color = (1, 1, 1, alpha)
    cap.data.update()
    return cap


caps = [eyelid(1), eyelid(-1)]
body.shape_key_add(name="Basis")
recess = body.shape_key_add(name="BlinkEyesRecess")
for v in body.data.vertices:
    p = v.co
    radius = min(
        math.sqrt(((p.x - side*0.15)/0.12)**2 + ((p.z - 0.62)/0.11)**2)
        for side in (1, -1)
    )
    weight = smooth((1.25-radius)/0.35) * smooth((-p.y-0.18)/0.05)
    recess.data[v.index].co.y = p.y + 0.075 * weight
lines = []
for side, cap in zip((1, -1), caps):
    points = [(side * 0.15 + x * 0.055, 0.62) for x in (-1, -0.5, 0, 0.5, 1)]
    curve = bpy.data.curves.new("Closed Eye Line", "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = 0.0025
    curve.bevel_resolution = 3
    spline = curve.splines.new("POLY")
    spline.points.add(len(points) - 1)
    for index, ((x, z), point) in enumerate(zip(points, spline.points)):
        point.co = (x, face_y(x, z) - 0.007, z, 1)
    line = bpy.data.objects.new(f"Closed_Eye_Line_{'L' if side > 0 else 'R'}", curve)
    bpy.context.collection.objects.link(line)
    curve.materials.append(black)
    lines.append(line)

scene = bpy.context.scene
for cap, line in zip(caps, lines):
    cap.hide_render = True
    line.hide_render = True
body.data.shape_keys.key_blocks["BlinkEyesRecess"].value = 0
scene.render.filepath = str(out / "blink-cap-neutral.png")
bpy.ops.render.render(write_still=True)
for cap, line in zip(caps, lines):
    cap.hide_render = False
    line.hide_render = False
body.data.shape_keys.key_blocks["BlinkEyesRecess"].value = 1
scene.render.filepath = str(out / "blink-cap-closed.png")
bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(out / "blink-cap-probe.blend"))
print("BLINK_CAP_POLYGONS", [len(cap.data.polygons) for cap in caps])
