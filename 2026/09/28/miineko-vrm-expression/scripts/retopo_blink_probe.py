"""Local regular eye patches: compress eye markings while retaining volume.

Distinct from a sliding lid: a stylized squint with a continuously deforming
skin patch. Source geometry is recessed only behind the patch. No whole-head
replacement, face-local rebake, or Blender-only driver is used.
"""
import bpy
import hashlib
import json
import math
import os
from pathlib import Path

import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts'/os.environ.get('BLINK_RUN','retopo-blink')
OUT.mkdir(exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'artifacts/base-vrm.blend'))
body=bpy.data.objects['Miineko_Body'];arm=bpy.data.objects['Miineko_Rig']
mesh=body.data;mesh.calc_loop_triangles()
triangles=list(mesh.loop_triangles);points=[v.co.copy() for v in mesh.vertices]
bvh=BVHTree.FromPolygons(points,[list(t.vertices) for t in triangles],all_triangles=True)
mat=mesh.materials[0]
img=next(n.image for n in mat.node_tree.nodes if n.type=='TEX_IMAGE' and n.image and 'BaseColor' in n.image.filepath)
w,h=img.size;pixels=np.empty(w*h*4,dtype=np.float32)
img.pixels.foreach_get(pixels);pixels=pixels.reshape(h,w,4)

def smooth(t):
    t=np.clip(t,0,1);return t*t*(3-2*t)

def sample(x,z):
    hit,_,index,_=bvh.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))
    if hit is None:raise RuntimeError('Patch misses head')
    tri=triangles[index];a,b,c=[points[i] for i in tri.vertices]
    v0,v1,v2=b-a,c-a,hit-a
    d00,d01,d11,d20,d21=v0.dot(v0),v0.dot(v1),v1.dot(v1),v2.dot(v0),v2.dot(v1)
    den=d00*d11-d01*d01;wb=(d11*d20-d01*d21)/den;wc=(d00*d21-d01*d20)/den
    uv=[mesh.uv_layers[0].data[i].uv for i in tri.loops]
    u=uv[0]*(1-wb-wc)+uv[1]*wb+uv[2]*wc
    fx=np.clip(u.x*w-.5,0,w-1.001);fz=np.clip(u.y*h-.5,0,h-1.001)
    i,j=int(fx),int(fz);tx,tz=fx-i,fz-j
    rgb=(pixels[j,i,:3]*(1-tx)+pixels[j,i+1,:3]*tx)*(1-tz)+(pixels[j+1,i,:3]*(1-tx)+pixels[j+1,i+1,:3]*tx)*tz
    linear=np.where(rgb<=.04045,rgb/12.92,((rgb+.055)/1.055)**2.4)
    return hit.y,linear

# Copy only the established lights/camera, not the old face mask.
with bpy.data.libraries.load(str(ROOT/'artifacts/mask-probe.blend'),link=False) as (src,dst):
    dst.objects=[name for name in src.objects if name.startswith(('Camera','Softbox'))]
    dst.worlds=src.worlds
for obj in dst.objects:bpy.context.collection.objects.link(obj)
scene=bpy.context.scene;scene.world=dst.worlds[0]
camera=next(o for o in dst.objects if o.type=='CAMERA');scene.camera=camera
camera.data.ortho_scale=.82
scene.render.engine='CYCLES';scene.cycles.samples=16;scene.cycles.seed=17
scene.render.resolution_x=scene.render.resolution_y=720;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'

def render(name,angle):
    a=math.radians(angle);camera.location=(2.5*math.sin(a),-2.5*math.cos(a),.64)
    camera.rotation_euler=(Vector((0,0,.64))-camera.location).to_track_quat('-Z','Y').to_euler()
    scene.render.filepath=str(OUT/f'{name}-{angle}.png');bpy.ops.render.render(write_still=True)

views=[int(x) for x in os.environ.get('BLINK_VIEWS','0,45,90').split(',')]
for angle in views:render('source',angle)

def material(name):
    m=bpy.data.materials.new(name);m.use_nodes=True;m.surface_render_method='BLENDED'
    nodes,links=m.node_tree.nodes,m.node_tree.links
    bsdf=next(n for n in nodes if n.type=='BSDF_PRINCIPLED');bsdf.inputs['Roughness'].default_value=.7
    vc=nodes.new('ShaderNodeVertexColor');vc.layer_name='SourceColor'
    tint=nodes.new('ShaderNodeMix');tint.data_type='RGBA';tint.blend_type='MULTIPLY';tint.inputs[0].default_value=1
    tint.inputs[6].default_value=(1,1,1,1)
    links.new(vc.outputs['Color'],tint.inputs[7]);links.new(tint.outputs[2],bsdf.inputs['Base Color'])
    links.new(vc.outputs['Alpha'],bsdf.inputs['Alpha'])
    return m,tint

keys=[];tints=[];stats={}
N=129;RX=.115;RZ=.12
for side,cx in [('L',.1764),('R',-.1848)]:
    cz=.619
    xx,zz=np.meshgrid(np.linspace(-RX,RX,N),np.linspace(-RZ,RZ,N))
    ys=np.empty_like(xx);rgb=np.empty((N,N,3))
    for j in range(N):
        for i in range(N):ys[j,i],rgb[j,i]=sample(cx+xx[j,i],cz+zz[j,i])
    # Smooth only the endpoint geometry. Open retains the sampled source form.
    # Remove piecewise-planar ray interpolation facets before building normals.
    for _ in range(16):
        p=ys.copy()
        ys[1:-1,1:-1]=.5*p[1:-1,1:-1]+.125*(p[:-2,1:-1]+p[2:,1:-1]+p[1:-1,:-2]+p[1:-1,2:])
    closed_y=ys.copy()
    for _ in range(220):
        p=closed_y.copy()
        closed_y[1:-1,1:-1]=.5*p[1:-1,1:-1]+.125*(p[:-2,1:-1]+p[2:,1:-1]+p[1:-1,:-2]+p[1:-1,2:])
    verts=[];target=[];colors=[];faces=[]
    for j in range(N):
        for i in range(N):
            x,z=xx[j,i],zz[j,i];r=max(abs(x/RX),abs(z/RZ))
            alpha=float(1-smooth((r-.94)/.06))
            verts.append((cx+x,ys[j,i]-.0005,cz+z))
            # Elliptical eye region narrows to a line, while the outer boundary
            # stays fixed. Expanded pink skin supplies the closed lid surface.
            eye_h=.096*math.sqrt(max(0,1-(x/.098)**2))
            if eye_h<.002:
                nz=z
            elif abs(z)<=eye_h:
                nz=z*.025
            else:
                nz=math.copysign(eye_h*.025+(abs(z)-eye_h)*(RZ-eye_h*.025)/(RZ-eye_h),z)
            curve=.009*max(0,1-(x/.098)**2)*float(1-smooth((abs(z/RZ)-.80)/.20))
            nz+=curve
            fy=np.clip((nz+RZ)/(2*RZ)*(N-1),0,N-1.001);k=int(fy);t=fy-k
            dy=closed_y[k,i]*(1-t)+closed_y[k+1,i]*t
            target.append((cx+x,dy-.0005,cz+nz))
            colors.append((*rgb[j,i],alpha))
    for j in range(N-1):
        for i in range(N-1):faces.append((j*N+i,j*N+i+1,(j+1)*N+i+1,(j+1)*N+i))
    patch=bpy.data.meshes.new(f'Eye patch {side}');patch.from_pydata(verts,[],faces);patch.update()
    obj=bpy.data.objects.new(f'Eye patch {side}',patch);bpy.context.collection.objects.link(obj);obj.parent=arm
    group=obj.vertex_groups.new(name='J_Bip_C_Head');group.add(list(range(len(verts))),1,'REPLACE')
    obj.modifiers.new('Armature','ARMATURE').object=arm
    vc=patch.color_attributes.new(name='SourceColor',type='FLOAT_COLOR',domain='CORNER')
    for loop in patch.loops:vc.data[loop.index].color=colors[loop.vertex_index]
    patch.color_attributes.active_color=vc
    base,_=material(f'Eye skin {side}');highlight,tint=material(f'Eye highlight {side}')
    patch.materials.append(base);patch.materials.append(highlight)
    for p in patch.polygons:
        p.use_smooth=True
        # Only faces touching the white glint are tinted during closure.
        if any(min(colors[i][:3])>.45 and abs(verts[i][0]-cx)<.095 and abs(verts[i][2]-cz)<.09 for i in p.vertices):p.material_index=1
    obj.shape_key_add(name='Basis');key=obj.shape_key_add(name='Close');keys.append(key);tints.append(tint)
    for i,co in enumerate(target):key.data[i].co=co
    for name in ('blink','blink_left' if side=='L' else 'blink_right'):
        expr=getattr(arm.data.vrm_addon_extension.vrm1.expressions.preset,name)
        bind=expr.morph_target_binds.add();bind.node.mesh_object_name=obj.name;bind.index='Close';bind.weight=1
        cb=expr.material_color_binds.add();cb.material=highlight;cb.type='color';cb.target_value=(.004,.004,.004,1)
    # Recess the old surface behind all patch states, only within this footprint.
    changed=0
    for v in mesh.vertices:
        p=v.co;dx,dz=p.x-cx,p.z-cz;r=max(abs(dx/RX),abs(dz/RZ))
        if r>=1 or p.y>=-.1:continue
        amount=.045*float(1-smooth((r-.65)/.17))
        v.co.y+=amount
        if amount>0:changed+=1
    stats[side]={'sourceVerticesRecessed':changed,'patchVertices':len(verts)}

mesh.update()
for weight in (0,.25,.5,.75,1):
    for key in keys:key.value=weight
    for tint in tints:tint.inputs[6].default_value=(1-.996*weight,)*3+(1,)
    for angle in views:render(f'wipe-{weight:g}',angle)
for key in keys:key.value=0
for tint in tints:tint.inputs[6].default_value=(1,1,1,1)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(OUT/'continuous-blink.vrm'))
report={'method':'local-retopo-squint','blender':bpy.app.version_string,'grid':N,'radius':[RX,RZ],'eyes':stats,'export':sorted(result),'scriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n');print('RETOPO',json.dumps(report))
