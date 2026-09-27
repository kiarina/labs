"""A small cartoon aa opening under the preserved source W smile.

The source head, nose, lips and eye expressions are unchanged. The new black
surface is collapsed along the measured mouth curve at zero weight. This is a
cartoon depiction of an opening, not a reconstructed anatomical oral cavity.
"""
import hashlib
import json
import math
import os
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'artifacts/overlay-selected-plus'
OUT=ROOT/'artifacts'/os.environ.get('MOUTH_RUN','mouth-aa-cartoon')
if OUT.resolve() in (SOURCE.resolve(),(ROOT/'artifacts/continuous-fresh').resolve()):
    raise ValueError('Preserve the owner-selected inputs')
OUT.mkdir(exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(SOURCE/'continuous-blink.blend'))
body=bpy.data.objects['Miineko_Body'];arm=bpy.data.objects['Miineko_Rig']
mesh=body.data;mesh.calc_loop_triangles()
triangles=list(mesh.loop_triangles)
positions=[v.co.copy() for v in mesh.vertices]
bvh=BVHTree.FromPolygons(positions,[list(t.vertices) for t in triangles],all_triangles=True)
image=next(n.image for n in mesh.materials[0].node_tree.nodes if n.type=='TEX_IMAGE' and n.image and 'BaseColor' in n.image.filepath)
iw,ih=image.size;pixels=np.empty(iw*ih*4,np.float32);image.pixels.foreach_get(pixels);pixels=pixels.reshape(ih,iw,4)

def sample(x,z):
    hit,_,index,_=bvh.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))
    if hit is None:raise ValueError('Mouth ray misses source')
    tri=triangles[index];a,b,c=[positions[i] for i in tri.vertices]
    v0,v1,v2=b-a,c-a,hit-a
    d00,d01,d11=v0.dot(v0),v0.dot(v1),v1.dot(v1)
    d20,d21=v2.dot(v0),v2.dot(v1);den=d00*d11-d01*d01
    wb=(d11*d20-d01*d21)/den;wc=(d00*d21-d01*d20)/den
    coords=[mesh.uv_layers[0].data[i].uv for i in tri.loops]
    uv=coords[0]*(1-wb-wc)+coords[1]*wb+coords[2]*wc
    color=pixels[min(ih-1,max(0,int(uv.y*ih))),min(iw-1,max(0,int(uv.x*iw))),:3]
    return hit.y,color

width=float(os.environ.get('MOUTH_WIDTH','.076'))
floor=float(os.environ.get('MOUTH_FLOOR','.423'))
onset=os.environ.get('MOUTH_ONSET','center')
assert onset in ('center','lower-rim')
cols,rows=161,17
xs=np.linspace(-width,width,cols)
curve=[]
for x in xs:
    prior=.477-.032*math.sin(math.pi*min(1,abs(x)/.081))
    samples=[]
    for z in np.linspace(prior-.012,prior+.012,65):
        y,color=sample(float(x),float(z))
        if color.max()<.12:samples.append((z,y))
    if not samples:raise ValueError(f'No source dark mouth at x={x}')
    # Stay on the visible black ridge, not the front/back limits of its UV islands.
    z=float(np.median([p[0] for p in samples]))
    curve.append((z,sample(float(x),z)[0],float(np.percentile([p[0] for p in samples],10))))
curve=np.asarray(curve)
# Suppress sub-pixel texture/ray selection jitter without changing the W design.
for _ in range(3):
    old=curve.copy();curve[1:-1]=.25*old[:-2]+.5*old[1:-1]+.25*old[2:]

base=[];opened=[];faces=[]
for j in range(rows):
    t=j/(rows-1)
    for i,x in enumerate(xs):
        z0,y0,zlow=curve[i]
        taper=max(0,1-(x/width)**2)
        bottom=min(z0-.003*taper,floor+(.479-floor)*(x/width)**2)
        z=z0+(bottom-z0)*t
        y=sample(float(x),float(z))[0]
        # Anchor inside the source black rim. Tiny forward clearance avoids
        # interpenetration without the old several-centimeter recession.
        if onset=='lower-rim':
            # Degenerate at neutral regardless of depth. Starting at the lower
            # dark rim makes tiny positive weights visible sooner, without
            # moving or repainting the original smile.
            base.append((x,sample(float(x),float(zlow))[0]-.0008,zlow))
        else:
            base.append((x,y0+.0003,z0))
        opened.append((x,y+.0003-.0013*t,z))
for j in range(rows-1):
    for i in range(cols-1):
        a=j*cols+i;faces.append((a,a+cols,a+cols+1,a+1))
data=bpy.data.meshes.new('Cartoon mouth opening');data.from_pydata(base,[],faces);data.update()
obj=bpy.data.objects.new('Mouth_Cartoon',data);bpy.context.collection.objects.link(obj)
obj.parent=arm
group=obj.vertex_groups.new(name='J_Bip_C_Head');group.add(list(range(len(base))),1,'REPLACE')
obj.modifiers.new('Armature','ARMATURE').object=arm
for p in data.polygons:p.use_smooth=True
mat=bpy.data.materials.new('Cartoon mouth dark');mat.use_nodes=True
mat.node_tree.nodes.clear()
emission=mat.node_tree.nodes.new('ShaderNodeEmission');emission.inputs['Color'].default_value=(.002,.0007,.0015,1)
output=mat.node_tree.nodes.new('ShaderNodeOutputMaterial');mat.node_tree.links.new(emission.outputs[0],output.inputs['Surface'])
mat.use_backface_culling=False;data.materials.append(mat)
obj.shape_key_add(name='Basis');key=obj.shape_key_add(name='AA')
for i,co in enumerate(opened):key.data[i].co=co
expr=arm.data.vrm_addon_extension.vrm1.expressions.preset.aa
expr.morph_target_binds.clear();expr.texture_transform_binds.clear();expr.material_color_binds.clear()
expr.is_binary=False
bind=expr.morph_target_binds.add();bind.node.mesh_object_name=obj.name;bind.index='AA';bind.weight=1
keys=[key]
tongue_enabled=os.environ.get('MOUTH_TONGUE')=='1'
if tongue_enabled:
    # Optional flat pink accent: no teeth, anatomical tongue or lip simulation.
    tongue_base=[];tongue_open=[];tongue_faces=[]
    nx,ny=73,9
    for j in range(ny):
        for x in np.linspace(-.035,.035,nx):
            z0=float(np.interp(x,xs,curve[:,0]));zlow=float(np.interp(x,xs,curve[:,2]))
            span=.26*math.sqrt(max(0,1-(x/.035)**2));t=.82+span*(j/(ny-1)-.5)
            taper=max(0,1-(x/width)**2)
            bottom=min(z0-.003*taper,floor+(.479-floor)*(x/width)**2)
            z=z0+(bottom-z0)*t
            bz=zlow if onset=='lower-rim' else z0
            by=sample(float(x),bz)[0]-.0010 if onset=='lower-rim' else sample(float(x),bz)[0]+.0001
            tongue_base.append((x,by,bz));tongue_open.append((x,sample(float(x),z)[0]-.0013,z))
    for j in range(ny-1):
        for i in range(nx-1):
            a=j*nx+i;tongue_faces.append((a,a+nx,a+nx+1,a+1))
    tm=bpy.data.meshes.new('Cartoon mouth pink accent');tm.from_pydata(tongue_base,[],tongue_faces);tm.update()
    to=bpy.data.objects.new('Mouth_Pink_Accent',tm);bpy.context.collection.objects.link(to);to.parent=arm
    vg=to.vertex_groups.new(name='J_Bip_C_Head');vg.add(list(range(len(tongue_base))),1,'REPLACE')
    to.modifiers.new('Armature','ARMATURE').object=arm
    pink=bpy.data.materials.new('Cartoon mouth pink');pink.use_nodes=True;pink.node_tree.nodes.clear()
    en=pink.node_tree.nodes.new('ShaderNodeEmission');en.inputs['Color'].default_value=(.35,.016,.055,1)
    output=pink.node_tree.nodes.new('ShaderNodeOutputMaterial');pink.node_tree.links.new(en.outputs[0],output.inputs['Surface'])
    tm.materials.append(pink)
    to.shape_key_add(name='Basis');tk=to.shape_key_add(name='AA')
    for i,co in enumerate(tongue_open):tk.data[i].co=co
    keys.append(tk)
    bind=expr.morph_target_binds.add();bind.node.mesh_object_name=to.name;bind.index='AA';bind.weight=1

scene=bpy.context.scene;camera=scene.camera;camera.data.ortho_scale=.82
scene.render.resolution_x=scene.render.resolution_y=720;scene.render.resolution_percentage=100
scene.cycles.samples=16;scene.cycles.seed=17
for weight in (0,.05,.25,.5,1):
    for k in keys:k.value=weight
    for angle in (0,45,-45):
        a=math.radians(angle);camera.location=(2.5*math.sin(a),-2.5*math.cos(a),.64)
        camera.rotation_euler=(Vector((0,0,.64))-camera.location).to_track_quat('-Z','Y').to_euler()
        scene.render.filepath=str(OUT/f'aa-{weight:g}-{angle}.png');bpy.ops.render.render(write_still=True)
for k in keys:k.value=0
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(OUT/'continuous-blink.vrm'))
report={'method':'cartoon-aa-under-source-smile','pinkAccent':tongue_enabled,'onset':onset,'blender':bpy.app.version_string,'width':width,'floor':floor,'vertices':len(base),'curve':curve.tolist(),'sourceVrmSha256':hashlib.sha256((SOURCE/'continuous-blink.vrm').read_bytes()).hexdigest(),'scriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'bodyVertexPositionsUnchanged':all(tuple(v.co)==tuple(p) for v,p in zip(mesh.vertices,positions)),'neutralMouthMaxPolygonArea':max(p.area for p in data.polygons),'export':sorted(result)}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print('MOUTH',json.dumps({k:v for k,v in report.items() if k!='curve'}))
