"""Bake the closed-eye BaseColor onto the mask's fixed local UV layout."""

from pathlib import Path

import bpy


out = Path(__file__).resolve().parents[1] / "artifacts"
bpy.ops.wm.open_mainfile(filepath=str(out / "mask-probe.blend"))
mask = bpy.data.objects["Miineko_Face_Mask_Neutral"]
source = bpy.data.images.load(str(out / "mask-uv-blink-texture.png"), check_existing=False)
target = bpy.data.images.new("Miineko_Face_Local_Blink", width=4096, height=4096, alpha=True)
target.generated_color = (0, 0, 0, 0)

material = bpy.data.materials.new("Blink Bake Source")
material.use_nodes = True
nodes = material.node_tree.nodes
nodes.clear()
links = material.node_tree.links
original_uv = nodes.new("ShaderNodeUVMap")
original_uv.uv_map = mask.data.uv_layers[0].name
source_node = nodes.new("ShaderNodeTexImage")
source_node.image = source
links.new(original_uv.outputs["UV"], source_node.inputs["Vector"])
emission = nodes.new("ShaderNodeEmission")
links.new(source_node.outputs["Color"], emission.inputs["Color"])
output = nodes.new("ShaderNodeOutputMaterial")
links.new(emission.outputs["Emission"], output.inputs["Surface"])
target_node = nodes.new("ShaderNodeTexImage")
target_node.image = target
for node in nodes:
    node.select = False
target_node.select = True
nodes.active = target_node
mask.data.materials.clear()
mask.data.materials.append(material)
mask.data.uv_layers.active = mask.data.uv_layers["FaceLocalUnwrapped"]
mask.data.uv_layers["FaceLocalUnwrapped"].active_render = True
for obj in bpy.context.selected_objects:
    obj.select_set(False)
mask.select_set(True)
bpy.context.view_layer.objects.active = mask
bpy.context.scene.render.engine = "CYCLES"
bpy.ops.object.bake(type="EMIT", margin=8)
target.filepath_raw = str(out / "face-local-blink.png")
target.file_format = "PNG"
target.save()
print("BAKED_IMAGE", target.filepath_raw)
