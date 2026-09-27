import bpy
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]/"artifacts"
bpy.ops.wm.open_mainfile(filepath=str(ROOT/"roundtrip.blend"))
arm=next(o for o in bpy.data.objects if o.type=="ARMATURE")
spring=arm.data.vrm_addon_extension.spring_bone1
spring.enable_animation=True
names=("Miineko_Ear_L_Root","Miineko_Ear_R_Root","Miineko_Tail_Root")

def rotations():
    return {n:list(arm.pose.bones[n].matrix.to_quaternion()) for n in names}

before=rotations()
head=arm.pose.bones["J_Bip_C_Head"]
head.rotation_mode="XYZ"
head.rotation_euler.x=.25
for _ in range(60):
    bpy.ops.vrm.update_spring_bone1_animation(delta_time=1/60)
after=rotations()
delta={n:max(abs(a-b) for a,b in zip(before[n],after[n])) for n in names}
report={"before":before,"after":after,"maxQuaternionDelta":delta,
        "springCount":len(spring.springs),"animationEnabled":spring.enable_animation}
(ROOT/"spring-test.json").write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps({"maxQuaternionDelta":delta,"springCount":len(spring.springs)},indent=2))
