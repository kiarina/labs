"""Render one-image atlas with only the face-mask material UV transform changed."""

from pathlib import Path

import bpy


out = Path(__file__).resolve().parents[1] / "artifacts"
bpy.ops.wm.open_mainfile(filepath=str(out / "mask-probe.blend"))
mask = bpy.data.objects["Miineko_Face_Mask_Neutral"]
body = next(obj for obj in bpy.data.objects if obj.type == "MESH" and obj != mask)
atlas = bpy.data.images.load(str(out / "miineko-expression-atlas.png"))

# The body reads the left half of the shared BaseColor image. Its other maps
# continue to use the original unscaled UV layer.
body_material = body.material_slots[0].material.copy()
body_material.name = "Body Original Region of Shared Atlas"
body.data.materials[0] = body_material
original_body_uv = body.data.uv_layers[0]
body_uv = body.data.uv_layers.new(name="AtlasOriginal")
for index, loop in enumerate(body.data.loops):
    value = original_body_uv.data[index].uv
    body_uv.data[index].uv = (value.x * 0.5, value.y)
body.data.uv_layers.active = original_body_uv
original_body_uv.active_render = True
body_atlas_uv = body_material.node_tree.nodes.new("ShaderNodeUVMap")
body_atlas_uv.uv_map = "AtlasOriginal"
for node in body_material.node_tree.nodes:
    if node.type == "TEX_IMAGE" and node.image and "BaseColor" in node.image.filepath:
        node.image = atlas
        body_material.node_tree.links.new(body_atlas_uv.outputs["UV"], node.inputs["Vector"])

# The copied full-face mask uses a separate material referencing the SAME
# image. Only its UV transform moves by one aligned expression-block width.
mask_material = bpy.data.materials.new("Mask Expression Atlas")
mask_material.use_nodes = True
nodes = mask_material.node_tree.nodes
nodes.clear()
links = mask_material.node_tree.links
local_uv = nodes.new("ShaderNodeUVMap")
local_uv.uv_map = "FaceLocalUnwrapped"
mapping = nodes.new("ShaderNodeMapping")
mapping.inputs["Scale"].default_value = (0.25, 0.5, 1)
mapping.inputs["Location"].default_value = (0.5, 0.5, 0)
links.new(local_uv.outputs["UV"], mapping.inputs["Vector"])
image = nodes.new("ShaderNodeTexImage")
image.image = atlas
image.extension = "CLIP"
links.new(mapping.outputs["Vector"], image.inputs["Vector"])
shader = nodes.new("ShaderNodeBsdfPrincipled")
links.new(image.outputs["Color"], shader.inputs["Base Color"])
shader.inputs["Roughness"].default_value = 0.7
output = nodes.new("ShaderNodeOutputMaterial")
links.new(shader.outputs["BSDF"], output.inputs["Surface"])
mask.data.materials.clear()
mask.data.materials.append(mask_material)

scene = bpy.context.scene
scene.render.filepath = str(out / "atlas-neutral.png")
bpy.ops.render.render(write_still=True)
mapping.inputs["Location"].default_value = (0.75, 0.5, 0)
scene.render.filepath = str(out / "atlas-blink.png")
bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(out / "atlas-probe.blend"))
