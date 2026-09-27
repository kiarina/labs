import bpy
import bmesh
import math
from pathlib import Path
from mathutils import Vector

OUT=Path(__file__).resolve().parents[1]/"artifacts"
bpy.ops.wm.open_mainfile(filepath=str(OUT/"base-vrm.blend"))
body=bpy.data.objects["Miineko_Body"]
arm=bpy.data.objects["Miineko_Rig"]
HEAD_Z=.63
RX,RY,RZ=.35,.32,.28

def surface_y(x,z):
    return -RY*math.sqrt(max(.01,1-(x/RX)**2-((z-HEAD_Z)/RZ)**2))

def material(name,color,roughness=.55):
    m=bpy.data.materials.new(name)
    m.diffuse_color=(*color,1)
    m.use_nodes=True
    b=next(n for n in m.node_tree.nodes if n.type=="BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value=(*color,1)
    b.inputs["Roughness"].default_value=roughness
    return m

skin=material("Miineko_Head_Pink",(.84,.001,.251),.67)
black=material("Miineko_Face_Black",(.003,.001,.003),.27)
white=material("Miineko_Eye_Glint",(.99,.99,.99),.27)

# Remove the original head; the replacement head covers the open neck.
bm=bmesh.new();bm.from_mesh(body.data)
remove=[]
for f in bm.faces:
    p=f.calc_center_median()
    if max(v.co.z for v in f.verts)>.39 or (p.z>.367 and p.y>-.105 and abs(p.x)<.25):
        remove.append(f)
print("removed head faces",len(remove))
bmesh.ops.delete(bm,geom=remove,context="FACES")
bm.to_mesh(body.data);bm.free();body.data.update()

def sphere(name,mat,center,scale,bone):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=64,ring_count=32)
    o=bpy.context.object
    o.name=name
    original=[]
    for v in o.data.vertices:
        p=v.co.copy()
        v.co=(center[0]+p.x*scale[0],center[1]+p.y*scale[1],center[2]+p.z*scale[2])
        original.append(v.co.copy())
    o.data.materials.append(mat)
    for poly in o.data.polygons:poly.use_smooth=True
    o.parent=arm
    vg=o.vertex_groups.new(name=bone)
    vg.add(list(range(len(o.data.vertices))),1,"REPLACE")
    mod=o.modifiers.new("Armature","ARMATURE");mod.object=arm
    o.shape_key_add(name="Basis")
    return o,original

head,_=sphere("Miineko_Head",skin,(0,0,HEAD_Z),(RX,RY,RZ),"J_Bip_C_Head")

def ear_mesh(side):
    def smooth_outline(points,steps=5):
        out=[]
        for i in range(len(points)):
            a=points[(i-1)%len(points)];b=points[i];c=points[(i+1)%len(points)];d=points[(i+2)%len(points)]
            for k in range(steps):
                t=k/steps;t2=t*t;t3=t2*t
                out.append(tuple(.5*((2*b[j])+(-a[j]+c[j])*t+(2*a[j]-5*b[j]+4*c[j]-d[j])*t2+(-a[j]+3*b[j]-3*c[j]+d[j])*t3) for j in range(2)))
        return out
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48,ring_count=24)
    o=bpy.context.object
    o.name=f"Miineko_Ear_{'L' if side>0 else 'R'}"
    me=o.data
    for v in me.vertices:
        p=v.co.copy()
        height=(p.z+1)*.5
        v.co=(side*(.270+.073*p.x*(1-.22*height)+.015*height),.036*p.y,.86+.135*p.z)
    me.materials.append(skin)
    for poly in me.polygons:poly.use_smooth=True
    o.parent=arm
    group=o.vertex_groups.new(name="J_Bip_C_Head")
    group.add(list(range(len(me.vertices))),1,"REPLACE")
    mod=o.modifiers.new("Armature","ARMATURE");mod.object=arm
    inner=smooth_outline([(.237,.845),(.269,.936),(.302,.961),(.313,.928),(.307,.852)])
    im=bpy.data.meshes.new(f"Miineko_Ear_Inner_{side}")
    im.from_pydata([(side*x,-.047,z) for x,z in inner],[],[tuple(range(len(inner)))])
    im.update()
    io=bpy.data.objects.new(f"Miineko_Ear_Inner_{'L' if side>0 else 'R'}",im)
    bpy.context.collection.objects.link(io);im.materials.append(white)
    io.parent=arm
    ig=io.vertex_groups.new(name="J_Bip_C_Head")
    ig.add(list(range(len(im.vertices))),1,"REPLACE")
    imod=io.modifiers.new("Armature","ARMATURE");imod.object=arm
    return o,io

for side in (1,-1):ear_mesh(side)

# Symmetric eye pivots with gaze defined on VRM's optional eye bones.
bpy.context.view_layer.objects.active=arm
for o in bpy.context.selected_objects:o.select_set(False)
arm.select_set(True)
bpy.ops.object.mode_set(mode="EDIT")
for side,name in ((1,"Miineko_Eye_L"),(-1,"Miineko_Eye_R")):
    b=arm.data.edit_bones.new(name)
    b.parent=arm.data.edit_bones["J_Bip_C_Head"]
    b.head=(side*.15,surface_y(side*.15,.62),.62)
    b.tail=(side*.15,surface_y(side*.15,.62)-.05,.62)
bpy.ops.object.mode_set(mode="OBJECT")
hum=arm.data.vrm_addon_extension.vrm1.humanoid.human_bones
hum.left_eye.node.bone_name="Miineko_Eye_L"
hum.right_eye.node.bone_name="Miineko_Eye_R"
arm.data.vrm_addon_extension.vrm1.look_at.type="bone"

eyes=[];glints=[]
for side in (1,-1):
    x=side*.15
    bone=f"Miineko_Eye_{'L' if side>0 else 'R'}"
    sy=surface_y(x,.62)
    eye,origin=sphere(f"Miineko_Eye_{'L' if side>0 else 'R'}_Mesh",black,(x,sy-.031,.62),(.068,.016,.070),bone)
    blink=eye.shape_key_add(name="Blink")
    for i,p in enumerate(origin):blink.data[i].co=(p.x,p.y-.004,.62+(p.z-.62)*.055)
    eyes.append(eye)
    hx=x-.020
    h,horig=sphere(f"Miineko_Eye_{'L' if side>0 else 'R'}_Glint",white,(hx,sy-.050,.647),(.014,.003,.014),bone)
    hk=h.shape_key_add(name="Blink")
    for i,p in enumerate(horig):hk.data[i].co=(p.x,p.y+.07,.62+(p.z-.62)*.05)
    glints.append(h)

nose,_=sphere("Miineko_Nose",black,(0,surface_y(0,.50)-.010,.50),(.028,.012,.017),"J_Bip_C_Head")

# A slim black smile follows the new head surface. Its Hide key accompanies
# mouth opening; each opening has a distinct black cavity morph.
cv=bpy.data.curves.new("Miineko_Smile_Curves","CURVE")
cv.dimensions="3D";cv.bevel_depth=.0035;cv.bevel_resolution=3
for side in (1,-1):
    sp=cv.splines.new("POLY");sp.points.add(20)
    for i,pt in enumerate(sp.points):
        t=i/20;x=side*.064*t;z=.461-.021*math.sin(math.pi*t)+.003*t
        pt.co=(x,surface_y(x,z)-.013,z,1)
sp=cv.splines.new("POLY");sp.points.add(10)
for i,pt in enumerate(sp.points):
    z=.493-(.493-.461)*i/10
    pt.co=(0,surface_y(0,z)-.017,z,1)
smile=bpy.data.objects.new("Miineko_Smile",cv)
bpy.context.collection.objects.link(smile)
for o in bpy.context.selected_objects:o.select_set(False)
smile.select_set(True);bpy.context.view_layer.objects.active=smile
bpy.ops.object.convert(target="MESH")
smile=bpy.context.object;smile.data.materials.append(black);smile.parent=arm
vg=smile.vertex_groups.new(name="J_Bip_C_Head");vg.add(list(range(len(smile.data.vertices))),1,"REPLACE")
mod=smile.modifiers.new("Armature","ARMATURE");mod.object=arm
smile.shape_key_add(name="Basis")
hide=smile.shape_key_add(name="Hide")
for i,v in enumerate(smile.data.vertices):hide.data[i].co.y=v.co.y+.07

mouth,base=sphere("Miineko_Mouth_Cavity",black,(0,surface_y(0,.445)+.06,.445),(.002,.001,.002),"J_Bip_C_Head")
for name,rx,rz in (("AA",.038,.034),("IH",.049,.015),("OU",.017,.026),("EE",.045,.012),("OH",.027,.036)):
    key=mouth.shape_key_add(name=name)
    for i,p in enumerate(base):
        ux=p.x/.002;uy=(p.y-(surface_y(0,.445)+.06))/.001;uz=(p.z-.445)/.002
        key.data[i].co=(ux*rx,surface_y(0,.445)-.019+uy*.004,.445+uz*rz)

world=bpy.data.worlds.new("Preview World");bpy.context.scene.world=world;world.use_nodes=True;world.node_tree.nodes.clear()
bg=world.node_tree.nodes.new("ShaderNodeBackground");bg.inputs["Color"].default_value=(.85,.85,.85,1);bg.inputs["Strength"].default_value=.8
wo=world.node_tree.nodes.new("ShaderNodeOutputWorld");world.node_tree.links.new(bg.outputs["Background"],wo.inputs["Surface"])
ld=bpy.data.lights.new("Softbox","AREA");ld.energy=500;ld.shape="DISK";ld.size=2
lo=bpy.data.objects.new("Softbox",ld);bpy.context.collection.objects.link(lo);lo.location=(-1.2,-1.5,2.5)
lo.rotation_euler=(Vector((0,0,.45))-lo.location).to_track_quat("-Z","Y").to_euler()
camd=bpy.data.cameras.new("Camera");cam=bpy.data.objects.new("Camera",camd);bpy.context.collection.objects.link(cam)
cam.location=(0,-2.5,.55);cam.rotation_euler=(Vector((0,0,.55))-cam.location).to_track_quat("-Z","Y").to_euler();camd.type="ORTHO";camd.ortho_scale=.72
scene=bpy.context.scene;scene.camera=cam;scene.render.engine="CYCLES";scene.cycles.samples=20
scene.render.resolution_x=850;scene.render.resolution_y=850;scene.render.resolution_percentage=100;scene.render.image_settings.file_format="PNG"
for label,blink,on_mouth,side in (("neutral",False,None,False),("blink",True,None,False),("aa",False,"AA",False),("side",False,None,True)):
    for eye in eyes+glints:eye.data.shape_keys.key_blocks["Blink"].value=1 if blink else 0
    smile.data.shape_keys.key_blocks["Hide"].value=1 if on_mouth else 0
    for key in mouth.data.shape_keys.key_blocks:key.value=1 if key.name==on_mouth else 0
    cam.location=(2.5,0,.55) if side else (0,-2.5,.55)
    cam.rotation_euler=(Vector((0,0,.55))-cam.location).to_track_quat("-Z","Y").to_euler()
    scene.render.filepath=str(OUT/f"replace-{label}.png");bpy.ops.render.render(write_still=True)
for eye in eyes+glints:eye.data.shape_keys.key_blocks["Blink"].value=0
smile.data.shape_keys.key_blocks["Hide"].value=0
for key in mouth.data.shape_keys.key_blocks:key.value=0
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/"face-replace.blend"))
