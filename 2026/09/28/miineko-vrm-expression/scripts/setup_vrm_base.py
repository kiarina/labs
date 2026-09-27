import bpy
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "artifacts"
bpy.ops.wm.open_mainfile(filepath=str(OUT / "imported.blend"))
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
mesh = next(o for o in bpy.data.objects if o.type == "MESH")
arm.name = "Miineko_Rig"
mesh.name = "Miineko_Body"

ext = arm.data.vrm_addon_extension
ext.spec_version = "1.0"
meta = ext.vrm1.meta
meta.vrm_name = "みぃねこ"
meta.version = "1.0"
meta.authors.add().value = "kiarina"
meta.avatar_permission = "onlyAuthor"
meta.commercial_usage = "personalNonProfit"
meta.allow_redistribution = False
meta.modification = "prohibited"

mapping = {
    "hips": "J_Bip_C_Hips", "spine": "J_Bip_C_Spine",
    "chest": "J_Bip_C_Chest", "upper_chest": "J_Bip_C_UpperChest",
    "neck": "J_Bip_C_Neck", "head": "J_Bip_C_Head",
}
for side in ("L", "R"):
    prefix = "left" if side == "L" else "right"
    for field, bone in (("shoulder", "Shoulder"), ("upper_arm", "UpperArm"), ("lower_arm", "LowerArm"), ("hand", "Hand"),
                        ("upper_leg", "UpperLeg"), ("lower_leg", "LowerLeg"), ("foot", "Foot"), ("toes", "ToeBase")):
        mapping[f"{prefix}_{field}"] = f"J_Bip_{side}_{bone}"
humanoid = ext.vrm1.humanoid.human_bones
for field, bone_name in mapping.items():
    getattr(humanoid, field).node.bone_name = bone_name

# Tripo's short-leg preset points the lower leg upward and the foot back up
# through the ankle. Put the required humanoid chain in anatomical order.
for obj in bpy.context.selected_objects:
    obj.select_set(False)
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
for side, x in (("L", .09354), ("R", -.09354)):
    upper = arm.data.edit_bones[f"J_Bip_{side}_UpperLeg"]
    lower = arm.data.edit_bones[f"J_Bip_{side}_LowerLeg"]
    foot = arm.data.edit_bones[f"J_Bip_{side}_Foot"]
    toes = arm.data.edit_bones[f"J_Bip_{side}_ToeBase"]
    upper.head = (x, -.017, .105)
    upper.tail = (x, -.017, .055)
    lower.head = upper.tail
    lower.tail = (x, -.017, .018)
    foot.head = lower.tail
    foot.tail = (x, -.077, .012)
    toes.head = foot.tail
    toes.tail = (x, -.115, .012)
bpy.ops.object.mode_set(mode="OBJECT")

for image in bpy.data.images:
    if image.filepath and image.source == "FILE":
        image.pack()

for obj in bpy.context.selected_objects:
    obj.select_set(False)
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "base-vrm.blend"))
result = bpy.ops.export_scene.vrm(filepath=str(OUT / "base-vrm.vrm"))
print("EXPORT_RESULT", result)
print("VRM_FILE", (OUT / "base-vrm.vrm").stat().st_size)
