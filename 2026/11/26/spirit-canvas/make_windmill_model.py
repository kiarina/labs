"""Builds a small windmill in Blender and exports it as a glTF binary (Part 13):
a stone tower, a roof, a door and a window that glows, four blades on a
hub that turn (animation "spin") and a flag on the roof that waves
(animation "flag"). Blender's front (-Y) becomes the side that faces the
viewer in a world. 1 Blender unit = 1 metre; the origin is the middle of
the base, on the ground.

blender --background --python make_windmill_model.py

Writes work/assets/media/models/windmill.glb (a "model" in canvas_media)
and work/logs/windmill-preview.png.
"""

import math
import os

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "work", "assets", "media", "models", "windmill.glb")
PREVIEW = os.path.join(HERE, "work", "logs", "windmill-preview.png")

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = 24
scene.frame_start, scene.frame_end = 0, 48
# New keys move evenly (a turn that loops without easing).
bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"


def material(name, color, roughness=0.7, metallic=0.0, glow=0.0):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if glow:
        bsdf.inputs["Emission Color"].default_value = (*color, 1)
        bsdf.inputs["Emission Strength"].default_value = glow
    return m


def srgb(hex_):
    """#RRGGBB to Blender's linear colour."""
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    h = hex_.lstrip("#")
    return tuple(lin(int(h[i:i + 2], 16)) for i in (0, 2, 4))


STONE = material("stone", srgb("#D9CFC0"), 0.9)
STONE_DARK = material("stone-dark", srgb("#9E948A"), 0.95)
ROOF = material("roof", srgb("#A8473B"), 0.6)
WOOD = material("wood", srgb("#7A5236"), 0.8)
SAIL = material("sail", srgb("#F3EBDD"), 0.85)
WINDOW = material("window", srgb("#FFC36B"), 0.4, glow=6.0)
FLAG = material("flag", srgb("#3E7BD6"), 0.7)
METAL = material("metal", srgb("#C9A44C"), 0.3, metallic=1.0)


def add(obj, mat, name, smooth=False):
    obj.name = name
    obj.data.materials.append(mat)
    if smooth:
        bpy.ops.object.shade_smooth()
    return obj


def cylinder(name, mat, r1, r2, depth, loc, verts=32):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r2, depth=depth, location=loc)
    return add(bpy.context.object, mat, name, smooth=True)


def box(name, mat, size, loc, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    return add(o, mat, name)


# The tower, a little narrower at the top, on a base ring.
cylinder("base", STONE_DARK, 1.05, 1.0, 0.25, (0, 0, 0.125))
cylinder("tower", STONE, 0.95, 0.7, 2.6, (0, 0, 0.25 + 1.3))
cylinder("rim", STONE_DARK, 0.78, 0.78, 0.12, (0, 0, 2.85 + 0.06))
cylinder("roof", ROOF, 0.85, 0.0, 1.0, (0, 0, 2.97 + 0.5))
# The door and a window facing the front (-Y), slightly out of the wall.
box("door", WOOD, (0.42, 0.08, 0.75), (0, -0.93, 0.25 + 0.375))
box("window", WINDOW, (0.32, 0.08, 0.36), (0, -0.78, 1.95))
box("window-frame", WOOD, (0.42, 0.06, 0.06), (0, -0.8, 1.75))
# The flag on the roof's tip.
cylinder("pole", METAL, 0.025, 0.025, 0.6, (0, 0, 3.47 + 0.3), verts=12)
flag = box("flag", FLAG, (0.35, 0.02, 0.22), (0.175, 0, 3.95))
flag_root = bpy.data.objects.new("flag-root", None)
scene.collection.objects.link(flag_root)
flag_root.location = (0, 0, 3.95)
flag.parent = flag_root
flag.location = (0.175, 0, 0)

# The hub out front, and four blades on it (wood arms with sails).
hub = bpy.data.objects.new("hub", None)
scene.collection.objects.link(hub)
hub.location = (0, -0.95, 2.55)
hub.rotation_mode = "XYZ"
cap = cylinder("hub-cap", METAL, 0.14, 0.1, 0.2, (0, 0, 0), verts=24)
cap.parent = hub
cap.rotation_euler = (math.radians(90), 0, 0)
cap.location = (0, -0.05, 0)
for i in range(4):
    a = i * math.pi / 2
    arm = box(f"arm{i}", WOOD, (0.07, 0.05, 1.7), (0, 0, 0))
    arm.parent = hub
    arm.rotation_euler = (0, a, 0)
    arm.location = (math.sin(a) * 0.85, -0.08, math.cos(a) * 0.85)
    sail = box(f"sail{i}", SAIL, (0.34, 0.02, 1.25), (0, 0, 0))
    sail.parent = hub
    sail.rotation_euler = (0, a, 0)
    off = 0.22
    sail.location = (math.sin(a) * 1.0 + math.cos(a) * off, -0.1, math.cos(a) * 1.0 - math.sin(a) * off)

# Animations: the blades turn once in 2 s; the flag swings.
hub.rotation_euler = (0, 0, 0)
hub.keyframe_insert("rotation_euler", index=1, frame=0)
hub.rotation_euler = (0, -2 * math.pi, 0)
hub.keyframe_insert("rotation_euler", index=1, frame=48)
hub.animation_data.action.name = "spin"
for f, z in [(0, -20), (12, 20), (24, -20), (36, 20), (48, -20)]:
    flag_root.rotation_euler = (0, 0, math.radians(z))
    flag_root.keyframe_insert("rotation_euler", index=2, frame=f)
flag_root.animation_data.action.name = "flag"

os.makedirs(os.path.dirname(OUT), exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=OUT,
    export_format="GLB",
    export_animation_mode="ACTIONS",
    export_apply=True,
    export_yup=True,
)
print("exported", OUT, os.path.getsize(OUT), "bytes")

# A preview: a camera in front and to the side, a sun, Eevee.
scene.frame_set(6)
cam = bpy.data.objects.new("camera", bpy.data.cameras.new("camera"))
scene.collection.objects.link(cam)
cam.location = (3.6, -6.2, 2.6)
direction = (0 - 3.6, 0 + 6.2, 2.0 - 2.6)
cam.rotation_euler = (
    math.atan2(math.hypot(direction[0], direction[1]), -direction[2]),
    0,
    math.atan2(direction[1], direction[0]) - math.pi / 2,
)
scene.camera = cam
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 3
sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(30))
scene.collection.objects.link(sun)
world = bpy.data.worlds.new("world")
world.color = (0.55, 0.7, 0.9)
scene.world = world
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x, scene.render.resolution_y = 640, 640
scene.render.filepath = PREVIEW
bpy.ops.render.render(write_still=True)
print("preview", PREVIEW)
