import bpy
import math
from pathlib import Path
from mathutils import Vector

OUT=Path(__file__).resolve().parents[1]/"artifacts"
bpy.ops.wm.open_mainfile(filepath=str(OUT/"face-replace.blend"))
arm=bpy.data.objects["Miineko_Rig"]
body=bpy.data.objects["Miineko_Body"]
eyes=[bpy.data.objects[f"Miineko_Eye_{side}_Mesh"] for side in ("L","R")]
glints=[bpy.data.objects[f"Miineko_Eye_{side}_Glint"] for side in ("L","R")]
smile=bpy.data.objects["Miineko_Smile"]
mouth=bpy.data.objects["Miineko_Mouth_Cavity"]
black=bpy.data.materials["Miineko_Face_Black"]
skin=bpy.data.materials["Miineko_Head_Pink"]
brow_black=bpy.data.materials.new("Miineko_Brow_Matte")
brow_black.diffuse_color=(.006,.003,.006,1)
brow_black.use_nodes=True
brow_bsdf=next(n for n in brow_black.node_tree.nodes if n.type=="BSDF_PRINCIPLED")
brow_bsdf.inputs["Base Color"].default_value=(.006,.003,.006,1)
brow_bsdf.inputs["Roughness"].default_value=.95

def surface_y(x,z):
    return -.32*math.sqrt(max(.01,1-(x/.35)**2-((z-.63)/.28)**2))

def bind(expression,obj,key,weight=1):
    assert key in obj.data.shape_keys.key_blocks,(obj.name,key)
    b=expression.morph_target_binds.add()
    b.node.mesh_object_name=obj.name
    b.index=key
    b.weight=weight

# Make all 17 requested preset expressions produce a visible morph. Bone-based
# LookAt remains the main automatic gaze mechanism; the four gaze presets also
# move glints when addressed directly as expressions.
for side,eye,glint in zip((1,-1),eyes,glints):
    original=[v.co.copy() for v in eye.data.vertices]
    for name in ("Happy","Angry","Sad","Relaxed","Surprised"):
        key=eye.shape_key_add(name=name)
        for i,p in enumerate(original):
            cx=side*.15
            if name=="Happy":
                key.data[i].co=(p.x,p.y,.62+(p.z-.62)*.28)
            elif name=="Angry":
                key.data[i].co=(p.x,p.y,.62+(p.z-.62)*.82+side*(p.x-cx)*.30)
            elif name=="Sad":
                key.data[i].co=(p.x,p.y,.62+(p.z-.62)*.78-side*(p.x-cx)*.23)
            elif name=="Relaxed":
                key.data[i].co=(p.x,p.y,.62+(p.z-.62)*.87)
            else:
                key.data[i].co=(cx+(p.x-cx)*.91,p.y-.004,.62+(p.z-.62)*1.13)
    for name,dx,dz in (("LookLeft",-.018,0),("LookRight",.018,0),("LookUp",0,.018),("LookDown",0,-.018)):
        key=glint.shape_key_add(name=name)
        for i,v in enumerate(glint.data.vertices):
            p=v.co
            key.data[i].co=(p.x+dx,p.y-.003,p.z+dz)
    happy_glint=glint.shape_key_add(name="Happy")
    for i,v in enumerate(glint.data.vertices):
        p=v.co
        happy_glint.data[i].co=(p.x,p.y+.07,.62+(p.z-.62)*.05)

for name in ("Happy","Angry","Sad","Relaxed"):
    key=smile.shape_key_add(name=name)
    for i,v in enumerate(smile.data.vertices):
        p=v.co;amount=min(1,abs(p.x)/.064)
        if name=="Happy":key.data[i].co=(p.x*1.17,p.y,p.z+.016*amount)
        elif name=="Angry":key.data[i].co=(p.x*.88,p.y,p.z-.008*amount)
        elif name=="Sad":key.data[i].co=(p.x*.92,p.y,p.z-.025*amount)
        else:key.data[i].co=(p.x*.95,p.y,p.z+.004*amount)

# Eyebrows are inside the head at rest. Emotional keys bring the black lines
# to the surface. They preserve the brow-free neutral design from the sheet.
def make_brow(side):
    mesh=bpy.data.meshes.new("Miineko_Brow_Mesh")
    verts=[];faces=[]
    n=20;m=8
    for i in range(n+1):
        t=i/n;x=side*(.105+.10*t);z=.758
        for j in range(m):
            a=2*math.pi*j/m
            verts.append((x+.0035*math.cos(a),0,.758+.0035*math.sin(a)))
    for i in range(n):
        for j in range(m):
            a=i*m+j;b=i*m+(j+1)%m;c=(i+1)*m+(j+1)%m;d=(i+1)*m+j
            faces.append((a,b,c,d))
    mesh.from_pydata(verts,[],faces);mesh.update()
    obj=bpy.data.objects.new(f"Miineko_Brow_{'L' if side>0 else 'R'}",mesh)
    bpy.context.collection.objects.link(obj)
    mesh.materials.append(brow_black)
    obj.parent=arm
    vg=obj.vertex_groups.new(name="J_Bip_C_Head")
    vg.add(list(range(len(mesh.vertices))),1,"REPLACE")
    mod=obj.modifiers.new("Armature","ARMATURE");mod.object=arm
    obj.shape_key_add(name="Basis")
    for name in ("Angry","Sad","Surprised"):
        key=obj.shape_key_add(name=name)
        for i,v in enumerate(mesh.vertices):
            t=(i//m)/n
            x=v.co.x
            if name=="Angry":z=.728+.045*t
            elif name=="Sad":z=.79-.040*t
            else:z=.79+.009*math.sin(math.pi*t)
            key.data[i].co=(x,surface_y(x,z)-.012,v.co.z+(z-.758))
    return obj
brows=[make_brow(1),make_brow(-1)]

ext=arm.data.vrm_addon_extension
preset=ext.vrm1.expressions.preset
for eye,glint in zip(eyes,glints):
    bind(preset.blink,eye,"Blink")
    bind(preset.blink,glint,"Blink")
bind(preset.blink_left,eyes[0],"Blink")
bind(preset.blink_left,glints[0],"Blink")
bind(preset.blink_right,eyes[1],"Blink")
bind(preset.blink_right,glints[1],"Blink")
for name in ("aa","ih","ou","ee","oh"):
    expr=getattr(preset,name)
    bind(expr,smile,"Hide")
    bind(expr,mouth,name.upper())
for name in ("happy","angry","sad","relaxed","surprised"):
    expr=getattr(preset,name)
    for eye in eyes:bind(expr,eye,name.capitalize())
    if name=="happy":
        for glint in glints:bind(expr,glint,"Happy")
    if name=="surprised":
        bind(expr,smile,"Hide")
        bind(expr,mouth,"OH")
    else:bind(expr,smile,name.capitalize())
    if name in ("angry","sad","surprised"):
        for brow in brows:bind(expr,brow,name.capitalize())
    expr.override_blink="blend"
    expr.override_mouth="blend"
for name,key in (("look_up","LookUp"),("look_down","LookDown"),("look_left","LookLeft"),("look_right","LookRight")):
    expr=getattr(preset,name)
    for glint in glints:bind(expr,glint,key)

# Eye-bone LookAt. Smaller output angles keep the glints within the black eyes.
look=ext.vrm1.look_at
look.type="bone"
look.offset_from_head_bone=(0,-.20,.20)
for r in (look.range_map_horizontal_inner,look.range_map_horizontal_outer):
    r.input_max_value=30;r.output_scale=12
for r in (look.range_map_vertical_up,look.range_map_vertical_down):
    r.input_max_value=25;r.output_scale=10

# Add actual spring joints for the two ears and tail. The ear assets are
# weighted along their height; tail weights replace only rear-center weights.
bpy.context.view_layer.objects.active=arm
for obj in bpy.context.selected_objects:obj.select_set(False)
arm.select_set(True)
bpy.ops.object.mode_set(mode="EDIT")
for side in (1,-1):
    name=f"Miineko_Ear_{'L' if side>0 else 'R'}"
    root=arm.data.edit_bones.new(name+"_Root")
    root.parent=arm.data.edit_bones["J_Bip_C_Head"]
    root.head=(side*.25,0,.83);root.tail=(side*.285,0,.92)
    tip=arm.data.edit_bones.new(name+"_Tip")
    tip.parent=root;tip.head=root.tail;tip.tail=(side*.31,0,.99)
tail_root=arm.data.edit_bones.new("Miineko_Tail_Root")
tail_root.parent=arm.data.edit_bones["J_Bip_C_Hips"]
tail_root.head=(0,.15,.21);tail_root.tail=(0,.245,.21)
tail_tip=arm.data.edit_bones.new("Miineko_Tail_Tip")
tail_tip.parent=tail_root;tail_tip.head=tail_root.tail;tail_tip.tail=(0,.325,.21)
bpy.ops.object.mode_set(mode="OBJECT")

for side in (1,-1):
    stem=f"Miineko_Ear_{'L' if side>0 else 'R'}"
    for objname in (stem,stem.replace("Ear_","Ear_Inner_")):
        ear=bpy.data.objects[objname]
        for g in list(ear.vertex_groups):ear.vertex_groups.remove(g)
        root_group=ear.vertex_groups.new(name=stem+"_Root")
        tip_group=ear.vertex_groups.new(name=stem+"_Tip")
        for v in ear.data.vertices:
            t=max(0,min(1,(v.co.z-.83)/.14))
            root_group.add([v.index],max(.001,1-t),"REPLACE")
            tip_group.add([v.index],max(.001,t),"REPLACE")

def smooth(t):
    t=max(0,min(1,t));return t*t*(3-2*t)
tail_root_group=body.vertex_groups.new(name="Miineko_Tail_Root")
tail_tip_group=body.vertex_groups.new(name="Miineko_Tail_Tip")
tail_count=0
for v in body.data.vertices:
    p=v.co
    w=smooth((p.y-.15)/.08)*smooth((p.z-.11)/.05)*smooth((.31-p.z)/.05)*smooth((.12-abs(p.x))/.06)
    if w<.02:continue
    old=[(g.group,g.weight) for g in v.groups if g.group not in (tail_root_group.index,tail_tip_group.index)]
    for index,weight in old:
        body.vertex_groups[index].add([v.index],max(0,weight*(1-w)),"REPLACE")
    t=smooth((p.y-.22)/.08)
    tail_root_group.add([v.index],w*(1-t),"REPLACE")
    tail_tip_group.add([v.index],w*t,"REPLACE")
    tail_count+=1
print("TAIL_VERTICES",tail_count)

trimmed=0
for v in body.data.vertices:
    influences=sorted(((g.group,g.weight) for g in v.groups if g.weight>0),key=lambda item:item[1],reverse=True)
    if len(influences)<=4:continue
    trimmed+=1
    keep=influences[:4]
    for index,_ in influences[4:]:body.vertex_groups[index].remove([v.index])
    total=sum(weight for _,weight in keep)
    for index,weight in keep:body.vertex_groups[index].add([v.index],weight/total,"REPLACE")
print("TRIMMED_TO_FOUR_INFLUENCES",trimmed)

springs=ext.spring_bone1.springs
for label,bones,center,stiffness,gravity,radius in (
    ("Left Ear",["Miineko_Ear_L_Root","Miineko_Ear_L_Tip"],"J_Bip_C_Head",1.2,.08,.006),
    ("Right Ear",["Miineko_Ear_R_Root","Miineko_Ear_R_Tip"],"J_Bip_C_Head",1.2,.08,.006),
    ("Tail",["Miineko_Tail_Root","Miineko_Tail_Tip"],"J_Bip_C_Hips",.8,.15,.014),
):
    spring=springs.add();spring.vrm_name=label;spring.center.bone_name=center
    for bone in bones:
        joint=spring.joints.add();joint.node.bone_name=bone
        joint.hit_radius=radius;joint.stiffness=stiffness
        joint.gravity_power=gravity;joint.drag_force=.45

# Keep editable source and the standalone VRM side by side in the workspace.
for obj in bpy.data.objects:
    if obj.type=="MESH" and obj.data.shape_keys:
        for key in obj.data.shape_keys.key_blocks:key.value=0
for img in bpy.data.images:
    if img.filepath and img.source=="FILE" and not img.packed_file:img.pack()
camera=bpy.data.objects.get("Camera")
if camera:
    camera.location=(0,-2.5,.5)
    camera.rotation_euler=(Vector((0,0,.5))-camera.location).to_track_quat("-Z","Y").to_euler()
    camera.data.ortho_scale=1.18
    bpy.context.scene.camera=camera
arm.select_set(True);bpy.context.view_layer.objects.active=arm
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/"miineko-vrm.blend"))
result=bpy.ops.export_scene.vrm(filepath=str(OUT/"miineko.vrm"))
print("EXPORT",result,"BYTES",(OUT/"miineko.vrm").stat().st_size)
