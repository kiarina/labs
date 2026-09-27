"""Copy the original face surface into a thin, UV-ready neutral mask.

This only tests the first gate: a neutral mask must preserve the FBX appearance.
It does not modify textures or create an expression atlas.
"""

import bmesh
import bpy
import math
import os
from pathlib import Path
from mathutils import Vector


source = os.environ.get("MIINEKO_FBX")
if not source:
    raise RuntimeError("Set MIINEKO_FBX to the local Tripo FBX path")
out = Path(__file__).resolve().parents[1] / "artifacts"
out.mkdir(exist_ok=True)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.fbx(filepath=source, use_image_search=True)
body = next(obj for obj in bpy.data.objects if obj.type == "MESH")

mask = body.copy()
mask.data = body.data.copy()
mask.name = "Miineko_Face_Mask_Neutral"
bpy.context.collection.objects.link(mask)
bm = bmesh.new()
bm.from_mesh(mask.data)
remove = []
for face in bm.faces:
    center = face.calc_center_median()
    within_face = (
        center.y < -0.09
        and face.normal.y < -0.10
        and ((center.x / 0.30) ** 2 + ((center.z - 0.63) / 0.25) ** 2) < 1
    )
    if not within_face:
        remove.append(face)
bmesh.ops.delete(bm, geom=remove, context="FACES")
bm.to_mesh(mask.data)
bm.free()
mask.data.update()

# A sub-millimeter normal offset avoids z-fighting. This is small relative to
# the ~1 m character and preserves the source face surface and its UVs.
for vertex in mask.data.vertices:
    vertex.co += vertex.normal * 0.0008
mask.data.update()

# New face-local UVs are stored but unused in the neutral render. The original
# material still samples the copied Tripo UV map, so any visual difference is
# caused by the mask geometry, normals or depth ordering rather than a bake.
local_uv = mask.data.uv_layers.new(name="FaceLocalProjection")
for loop in mask.data.loops:
    p = mask.data.vertices[loop.vertex_index].co
    local_uv.data[loop.index].uv = ((p.x + 0.31) / 0.62, (p.z - 0.37) / 0.52)
unwrapped_uv = mask.data.uv_layers.new(name="FaceLocalUnwrapped")
mask.data.uv_layers.active = unwrapped_uv
for edge in mask.data.edges:
    edge.use_seam = False
for obj in bpy.context.selected_objects:
    obj.select_set(False)
mask.select_set(True)
bpy.context.view_layer.objects.active = mask
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.unwrap(method="ANGLE_BASED", margin=0.02)
bpy.ops.object.mode_set(mode="OBJECT")
mask.data.uv_layers.active = mask.data.uv_layers.get("UVMap") or mask.data.uv_layers[0]

world = bpy.data.worlds.new("Neutral Probe World")
bpy.context.scene.world = world
world.use_nodes = True
world.node_tree.nodes.clear()
background = world.node_tree.nodes.new("ShaderNodeBackground")
background.inputs["Color"].default_value = (0.85, 0.85, 0.85, 1)
background.inputs["Strength"].default_value = 0.8
output = world.node_tree.nodes.new("ShaderNodeOutputWorld")
world.node_tree.links.new(background.outputs["Background"], output.inputs["Surface"])
for position, energy, size in (((-1.2, -1.5, 2.5), 550, 2.0), ((1.5, -0.4, 1.6), 320, 1.5)):
    light_data = bpy.data.lights.new("Softbox", "AREA")
    light_data.energy = energy
    light_data.shape = "DISK"
    light_data.size = size
    light = bpy.data.objects.new("Softbox", light_data)
    bpy.context.collection.objects.link(light)
    light.location = position
    light.rotation_euler = (Vector((0, 0, 0.45)) - light.location).to_track_quat("-Z", "Y").to_euler()
camera_data = bpy.data.cameras.new("Camera")
camera = bpy.data.objects.new("Camera", camera_data)
bpy.context.collection.objects.link(camera)
camera.location = (0, -2.5, 0.5)
camera.rotation_euler = (Vector((0, 0, 0.5)) - camera.location).to_track_quat("-Z", "Y").to_euler()
camera_data.type = "ORTHO"
camera_data.ortho_scale = 1.2
scene = bpy.context.scene
scene.camera = camera
scene.render.engine = "CYCLES"
scene.cycles.samples = 32
scene.render.resolution_x = 900
scene.render.resolution_y = 900
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"

mask.hide_render = True
scene.render.filepath = str(out / "mask-probe-original.png")
bpy.ops.render.render(write_still=True)
mask.hide_render = False
scene.render.filepath = str(out / "mask-probe-neutral.png")
bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(out / "mask-probe.blend"))
print("FACE_MASK", len(mask.data.vertices), "vertices", len(mask.data.polygons), "polygons")
