"""Builds two models with pictures on them in Blender and exports them as glTF
binaries (Part 14): an easel holding a painting (a picture from the labs test
assets on its canvas) and a desk globe wrapped in a street photo that turns
(animation "spin"). The pictures go inside the .glb. 1 Blender unit = 1
metre, front -Y, origin on the ground.

blender --background --python make_textured_models.py

Writes work/assets/media/models/{easel,globe}.glb and
work/logs/{easel,globe}-preview.png.
"""

import math
import os

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "tests", "assets", "jpg"))
MODELS = os.path.join(HERE, "work", "assets", "media", "models")
LOGS = os.path.join(HERE, "work", "logs")


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = 24
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    return scene


def lin(hex_):
    def c(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    h = hex_.lstrip("#")
    return tuple(c(int(h[i:i + 2], 16)) for i in (0, 2, 4))


def material(name, hex_, roughness=0.7, metallic=0.0):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*lin(hex_), 1)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return m


def picture(name, image_file, roughness=0.6):
    """A material whose colour is a picture (an Image Texture into Base Color)."""
    m = bpy.data.materials.new(name)
    nodes, links = m.node_tree.nodes, m.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = roughness
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(os.path.join(ASSETS, image_file))
    links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return m


def put(obj, mat, name, smooth=False):
    obj.name = name
    obj.data.materials.append(mat)
    if smooth:
        bpy.ops.object.shade_smooth()
    return obj


def box(name, mat, size, loc, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return put(o, mat, name)


def cylinder(name, mat, r1, r2, depth, loc, rot=(0, 0, 0), verts=24):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r2, depth=depth, location=loc, rotation=rot)
    return put(bpy.context.object, mat, name, smooth=True)


def export(name):
    os.makedirs(MODELS, exist_ok=True)
    path = os.path.join(MODELS, f"{name}.glb")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", export_animation_mode="ACTIONS",
                              export_apply=True, export_yup=True, export_image_format="JPEG",
                              export_jpeg_quality=85)
    print("exported", path, os.path.getsize(path), "bytes")


def preview(name, cam_loc, target):
    scene = bpy.context.scene
    cam = bpy.data.objects.new("camera", bpy.data.cameras.new("camera"))
    scene.collection.objects.link(cam)
    cam.location = cam_loc
    d = [t - c for t, c in zip(target, cam_loc)]
    cam.rotation_euler = (math.atan2(math.hypot(d[0], d[1]), -d[2]), 0, math.atan2(d[1], d[0]) - math.pi / 2)
    scene.camera = cam
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3
    sun.rotation_euler = (math.radians(45), math.radians(10), math.radians(-30))
    scene.collection.objects.link(sun)
    world = bpy.data.worlds.new("world")
    world.color = (0.5, 0.55, 0.6)
    scene.world = world
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = 640, 640
    scene.render.filepath = os.path.join(LOGS, f"{name}-preview.png")
    bpy.ops.render.render(write_still=True)


# --- the easel and its painting ---------------------------------------------------
reset()
WOOD = material("easel-wood", "#8A5A35", 0.75)
FRAME = material("frame-gold", "#C9A24A", 0.35, metallic=1.0)
# Two front legs leaning back, one back leg, a ledge.
for i, x in enumerate([-0.38, 0.38]):
    box(f"leg{i}", WOOD, (0.05, 0.05, 1.75), (x * 0.85, 0.05, 0.85), rot=(math.radians(-8), 0, math.radians(-8 if x < 0 else 8)))
box("leg-back", WOOD, (0.05, 0.05, 1.7), (0, 0.42, 0.8), rot=(math.radians(18), 0, 0))
box("ledge", WOOD, (0.8, 0.12, 0.05), (0, -0.04, 0.52))
box("top-bar", WOOD, (0.6, 0.05, 0.05), (0, 0.13, 1.58))
# The painting: 3:4 portrait, a gold frame round a picture plane facing -Y.
W, H, Y0 = 0.66, 0.88, 0.56
art = picture("painting", "miineko2_1086x1448_219kb.jpg", 0.55)
bpy.ops.mesh.primitive_plane_add(size=1, location=(0, -0.075, Y0 + H / 2), rotation=(math.radians(90 - 8), 0, 0))
plane = bpy.context.object
plane.scale = (W, H, 1)
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
put(plane, art, "painting")
t = 0.045
for name, size, off in [("frame-top", (W + 2 * t, 0.04, t), (0, H / 2 + t / 2)), ("frame-bottom", (W + 2 * t, 0.04, t), (0, -H / 2 - t / 2)),
                        ("frame-left", (t, 0.04, H), (-W / 2 - t / 2, 0)), ("frame-right", (t, 0.04, H), (W / 2 + t / 2, 0))]:
    a = math.radians(-8)
    x, z = off
    box(name, FRAME, size, (x, -0.07 + z * math.sin(-a) * 0 - z * math.sin(a), Y0 + H / 2 + z * math.cos(a)), rot=(a, 0, 0))
export("easel")
preview("easel", (1.4, -2.6, 1.3), (0, 0, 0.9))

# --- the desk globe -------------------------------------------------------------------
scene = reset()
scene.frame_start, scene.frame_end = 0, 96
BRASS = material("brass", "#C9A24A", 0.3, metallic=1.0)
DARK = material("base-wood", "#4A3020", 0.6)
cylinder("base", DARK, 0.22, 0.2, 0.06, (0, 0, 0.03), verts=40)
cylinder("stem", BRASS, 0.025, 0.025, 0.25, (0, 0, 0.06 + 0.125))
tilt = math.radians(23.4)
axis = bpy.data.objects.new("axis", None)
scene.collection.objects.link(axis)
axis.location = (0, 0, 0.58)
axis.rotation_euler = (0, tilt, 0)
# The meridian ring (a half torus) and the globe on the tilted axis.
bpy.ops.mesh.primitive_torus_add(major_radius=0.29, minor_radius=0.012, location=(0, 0, 0), rotation=(math.radians(90), 0, 0))
ring = put(bpy.context.object, BRASS, "meridian", smooth=True)
ring.parent = axis
spin = bpy.data.objects.new("spin", None)
scene.collection.objects.link(spin)
spin.parent = axis
bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=0.26, location=(0, 0, 0))
ball = put(bpy.context.object, picture("earth", "street_scene_1774x887_287kb.jpg", 0.4), "globe", smooth=True)
ball.parent = spin
spin.keyframe_insert("rotation_euler", index=2, frame=0)
spin.rotation_euler = (0, 0, 2 * math.pi)
spin.keyframe_insert("rotation_euler", index=2, frame=96)
spin.animation_data.action.name = "spin"
export("globe")
preview("globe", (0.9, -1.2, 0.85), (0, 0, 0.5))
