"""Bake the neutral Tripo face color onto the mask's face-local UV map."""

import bpy
from pathlib import Path


out = Path(__file__).resolve().parents[1] / "artifacts"
bpy.ops.wm.open_mainfile(filepath=str(out / "mask-probe.blend"))
mask = bpy.data.objects["Miineko_Face_Mask_Neutral"]
original_material = mask.material_slots[0].material
original_uv_name = mask.data.uv_layers[0].name
face_uv_name = "FaceLocalUnwrapped"
source_image = next(
    node.image
    for node in original_material.node_tree.nodes
    if node.type == "TEX_IMAGE" and node.image and "BaseColor" in node.image.filepath
)

bake_image = bpy.data.images.new(
    "Miineko_Face_Local_Neutral", width=4096, height=4096, alpha=True
)
bake_image.generated_color = (0, 0, 0, 0)
bake_material = original_material.copy()
bake_material.name = "Face Mask Neutral Bake Source"
mask.data.materials[0] = bake_material
nodes = bake_material.node_tree.nodes
nodes.clear()
links = bake_material.node_tree.links
old_uv = nodes.new("ShaderNodeUVMap")
old_uv.uv_map = original_uv_name
source_texture = nodes.new("ShaderNodeTexImage")
source_texture.image = source_image
links.new(old_uv.outputs["UV"], source_texture.inputs["Vector"])
emission = nodes.new("ShaderNodeEmission")
links.new(source_texture.outputs["Color"], emission.inputs["Color"])
output = nodes.new("ShaderNodeOutputMaterial")
links.new(emission.outputs["Emission"], output.inputs["Surface"])
target_texture = nodes.new("ShaderNodeTexImage")
target_texture.image = bake_image
for node in nodes:
    node.select = False
target_texture.select = True
nodes.active = target_texture

mask.data.uv_layers.active = mask.data.uv_layers[face_uv_name]
mask.data.uv_layers[face_uv_name].active_render = True
for obj in bpy.context.selected_objects:
    obj.select_set(False)
mask.select_set(True)
bpy.context.view_layer.objects.active = mask
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.bake_type = "EMIT"
bpy.ops.object.bake(type="EMIT", margin=8)
bake_image.filepath_raw = str(out / "face-local-neutral.png")
bake_image.file_format = "PNG"
bake_image.save()

# Display the baked color using a dedicated UV map while keeping the existing
# normal/roughness/metallic source maps fixed on the original Tripo UV map.
display_material = original_material.copy()
display_material.name = "Face Mask Neutral Local UV"
mask.data.materials[0] = display_material
display_nodes = display_material.node_tree.nodes
old_uv = display_nodes.new("ShaderNodeUVMap")
old_uv.uv_map = original_uv_name
face_uv = display_nodes.new("ShaderNodeUVMap")
face_uv.uv_map = face_uv_name
for node in display_nodes:
    if node.type != "TEX_IMAGE" or not node.image:
        continue
    if node.image == source_image:
        node.image = bake_image
        display_material.node_tree.links.new(face_uv.outputs["UV"], node.inputs["Vector"])
    else:
        display_material.node_tree.links.new(old_uv.outputs["UV"], node.inputs["Vector"])

scene.render.filepath = str(out / "mask-probe-baked.png")
bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(out / "mask-probe-baked.blend"))
print("BAKED_IMAGE", bake_image.filepath_raw)
