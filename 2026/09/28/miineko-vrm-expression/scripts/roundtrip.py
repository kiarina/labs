import bpy
import json
from pathlib import Path
from mathutils import Vector

ROOT=Path(__file__).resolve().parents[1]/"artifacts"
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
result=bpy.ops.import_scene.vrm(filepath=str(ROOT/"miineko.vrm"))
print("IMPORT",result)
arms=[o for o in bpy.data.objects if o.type=="ARMATURE"]
assert len(arms)==1,[(o.name,o.type) for o in bpy.data.objects]
arm=arms[0]
ext=arm.data.vrm_addon_extension
preset=ext.vrm1.expressions.preset
report={"armature":arm.name,"bones":len(arm.data.bones),"meshes":[o.name for o in bpy.data.objects if o.type=="MESH"],
        "images":[{"name":i.name,"size":list(i.size)} for i in bpy.data.images if i.size[0]>0],
        "springCount":len(ext.spring_bone1.springs),"lookAt":ext.vrm1.look_at.type,
        "expressionBinds":{name:len(getattr(preset,name).morph_target_binds) for name in
            ("happy","angry","sad","relaxed","surprised","blink","blink_left","blink_right",
             "aa","ih","ou","ee","oh","look_up","look_down","look_left","look_right")}}
(ROOT/"roundtrip-report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
print(json.dumps({k:v for k,v in report.items() if k!="meshes" and k!="images"},ensure_ascii=False))

world=bpy.data.worlds.new("Roundtrip Studio");bpy.context.scene.world=world;world.use_nodes=True;world.node_tree.nodes.clear()
bg=world.node_tree.nodes.new("ShaderNodeBackground");bg.inputs["Color"].default_value=(.85,.85,.85,1);bg.inputs["Strength"].default_value=.8
out=world.node_tree.nodes.new("ShaderNodeOutputWorld");world.node_tree.links.new(bg.outputs["Background"],out.inputs["Surface"])
ld=bpy.data.lights.new("Softbox","AREA");ld.energy=500;ld.shape="DISK";ld.size=2
lo=bpy.data.objects.new("Softbox",ld);bpy.context.collection.objects.link(lo);lo.location=(-1.2,-1.5,2.5)
lo.rotation_euler=(Vector((0,0,.45))-lo.location).to_track_quat("-Z","Y").to_euler()
camd=bpy.data.cameras.new("Camera");cam=bpy.data.objects.new("Camera",camd);bpy.context.collection.objects.link(cam)
cam.location=(0,-2.5,.5);cam.rotation_euler=(Vector((0,0,.5))-cam.location).to_track_quat("-Z","Y").to_euler();camd.type="ORTHO";camd.ortho_scale=1.18
scene=bpy.context.scene;scene.camera=cam;scene.render.engine="CYCLES";scene.cycles.samples=12
scene.render.resolution_x=800;scene.render.resolution_y=800;scene.render.resolution_percentage=100;scene.render.image_settings.file_format="PNG"
states=(("neutral",None),("blink","blink"),("aa","aa"),("happy","happy"),("angry","angry"),("sad","sad"),("relaxed","relaxed"),("surprised","surprised"),("look-left","look_left"))
for label,name in states:
    for _,expr in preset.expression_preset_and_expressions():expr.preview=0
    if name:getattr(preset,name).preview=1
    scene.render.filepath=str(ROOT/f"roundtrip-{label}.png")
    bpy.ops.render.render(write_still=True)
    print("RENDER",label)
for _,expr in preset.expression_preset_and_expressions():expr.preview=0
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/"roundtrip.blend"))
