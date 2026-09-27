"""Replace only eye-region faces and stitch patches to the original boundary.

This stylized squint preserves the rest of the head. Optional source normal
transfer and explicit normal morphs isolate shading from geometry defects.
No whole-head replacement or Blender-only runtime driver is used.
"""
import bpy
import hashlib
import json
import math
import os
from pathlib import Path

import numpy as np
TRANSFER_NORMALS=os.environ.get("BLINK_NORMALS") in ("source","morph")
MORPH_NORMALS=os.environ.get("BLINK_NORMALS")=="morph"
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts'/os.environ.get('BLINK_RUN','stitched-blink')
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

if TRANSFER_NORMALS:
    mesh.calc_tangents(uvmap=mesh.uv_layers[0].name)
    ni=next(n.image for n in mat.node_tree.nodes if n.type=='TEX_IMAGE' and n.image and 'Normal' in n.image.filepath)
    nw,nh=ni.size;normal_pixels=np.empty(nw*nh*4,dtype=np.float32);ni.pixels.foreach_get(normal_pixels);normal_pixels=normal_pixels.reshape(nh,nw,4)

def sample(x,z,with_normal=False):
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
    if with_normal:
        fx=np.clip(u.x*nw-.5,0,nw-1.001);fz=np.clip(u.y*nh-.5,0,nh-1.001)
        i,j=int(fx),int(fz);tx,tz=fx-i,fz-j
        nc=(normal_pixels[j,i,:3]*(1-tx)+normal_pixels[j,i+1,:3]*tx)*(1-tz)+(normal_pixels[j+1,i,:3]*(1-tx)+normal_pixels[j+1,i+1,:3]*tx)*tz
        bary=(1-wb-wc,wb,wc)
        normal=sum((mesh.corner_normals[l].vector*b for l,b in zip(tri.loops,bary)),Vector()).normalized()
        tangent=sum((mesh.loops[l].tangent*b for l,b in zip(tri.loops,bary)),Vector()).normalized()
        sign=sum(mesh.loops[l].bitangent_sign*b for l,b in zip(tri.loops,bary))
        bitangent=normal.cross(tangent)*(-1 if sign<0 else 1)
        nx,ny,nz=nc*2-1
        result=(tangent*nx+bitangent*ny+normal*nz).normalized()
        return hit.y,linear,result
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

# Replace selected faces and reuse their boundary vertices. This removes the
# overlapping shells and recessed-face trench of the previous grid experiment.
original_normals=[n.vector.copy() for n in mesh.corner_normals]
allverts=[tuple(v.co) for v in mesh.vertices]
closedverts=[tuple(v.co) for v in mesh.vertices]
allfaces=[];face_uv=[];face_colors=[];face_mats=[];face_normals=[];face_smooth=[]
removed=set();boundaries=set();patches=[];materials=[mat];tints=[];stats={};base_normals={};target_normals={};vertex_sides={}
RX=float(os.environ.get("STITCH_RX",".118"));RZ=float(os.environ.get("STITCH_RZ",".124"));RINGS=64;SUBDIV=6
for side,cx in [('L',.1764),('R',-.1848)]:
    cz=.619
    selected={p.index for p in mesh.polygons if p.center.y<-.1 and ((p.center.x-cx)/RX)**2+((p.center.z-cz)/RZ)**2<1}
    edges={}
    for index in selected:
        p=mesh.polygons[index]
        for a,b in zip(p.vertices,list(p.vertices[1:])+[p.vertices[0]]):
            key=tuple(sorted((a,b)));edges[key]=edges.get(key,0)+1
    boundary_edges=[edge for edge,count in edges.items() if count==1]
    adjacency={}
    for a,b in boundary_edges:adjacency.setdefault(a,[]).append(b);adjacency.setdefault(b,[]).append(a)
    assert all(len(n)==2 for n in adjacency.values()),'Non-manifold selection boundary'
    first=min(adjacency);order=[first];prev=None;current=first
    while True:
        next_index=next(n for n in adjacency[current] if n!=prev)
        if next_index==first:break
        order.append(next_index);prev,current=current,next_index
        assert len(order)<=len(adjacency)
    assert len(order)==len(adjacency),'More than one hole boundary'
    # Counter-clockwise in projected X/Z produces outward normals toward -Y.
    area=sum(points[a].x*points[b].z-points[b].x*points[a].z for a,b in zip(order,order[1:]+order[:1]))
    if area<0:order.reverse()
    falloff_end=min(math.hypot((points[i].x-cx)/RX,(points[i].z-cz)/RZ) for i in order)*.97
    removed.update(selected);boundaries.update(order)
    base,_=material(f'Stitched eye skin {side}');highlight,tint=material(f'Stitched eye highlight {side}')
    materials.extend((base,highlight));base_idx=len(materials)-2;tints.append((side,tint,highlight))
    # A thin circular core avoids putting the triangular pole inside the glint.
    rings=[];color_lookup={i:sample(points[i].x,points[i].z)[1] for i in order}
    normal_lookup={}
    new_indices=[]
    fit_points=[]
    for fx in np.linspace(-.10,.10,19):
        for fz in np.linspace(-.10,.10,19):
            if (fx/.10)**2+(fz/.10)**2<1:
                fit_points.append((fx,fz,sample(cx+fx,cz+fz)[0]))
    fp=np.asarray(fit_points);fx,fz,fy=fp.T
    A=np.stack([np.ones_like(fx),fx,fz,fx*fx,fx*fz,fz*fz],axis=-1)
    coeff=np.linalg.lstsq(A,fy,rcond=None)[0]
    def target_normal(x,z,r):
        dx,dz=x-cx,z-cz
        n=Vector((coeff[1]+2*coeff[3]*dx+coeff[4]*dz,-1,coeff[2]+coeff[4]*dx+2*coeff[5]*dz)).normalized()
        original=sample(x,z,True)[2]
        fade=float(smooth((r-.78)/.22))
        return (n*(1-fade)+original*fade).normalized()
    for ring in range(RINGS-1,0,-1):
        r=ring/RINGS;ids=[]
        for k in range(len(order)*SUBDIV):
            outer=order[k//SUBDIV];next_outer=order[(k//SUBDIV+1)%len(order)]
            t=(k%SUBDIV)/SUBDIV
            edge=points[outer]*(1-t)+points[next_outer]*t
            x=cx+(edge.x-cx)*r;z=cz+(edge.z-cz)*r
            y,rgb=sample(x,z)
            if TRANSFER_NORMALS:normal_lookup[len(allverts)]=sample(x,z,True)[2]
            # Compact smoothing for ray-triangle facets, preserving the boundary.
            local=[sample(x+dx,z+dz)[0] for dx,dz in ((-.004,0),(.004,0),(0,-.004),(0,.004))]
            y=.5*y+.125*sum(local)
            idx=len(allverts);ids.append(idx);new_indices.append(idx);allverts.append((x,y,z));color_lookup[idx]=rgb
            rho=math.hypot((x-cx)/RX,(z-cz)/RZ)
            if os.environ.get('BLINK_WARP')=='physical':
                influence=1-float(smooth((rho-.70)/(falloff_end-.70)))
            else:
                influence=1-float(smooth((r-.77)/.23))
            nz=cz+(z-cz)*(1-.975*influence)+.009*max(0,1-((x-cx)/.10)**2)*influence
            # Closed skin follows the original overall eye volume; no source
            # face remains beneath this patch to intersect it.
            cy=sample(x,nz)[0]
            local=[sample(x+dx,nz+dz)[0] for dx,dz in ((-.005,0),(.005,0),(0,-.005),(0,.005))]
            cy=.5*cy+.125*sum(local)
            if os.environ.get('BLINK_CLOSED_SURFACE')=='smooth':
                dx,dz=x-cx,nz-cz
                fitted=coeff@np.asarray((1,dx,dz,dx*dx,dx*dz,dz*dz))
                fade=float(smooth((math.hypot(dx/RX,dz/RZ)-.70)/(falloff_end-.70))) if os.environ.get('BLINK_WARP')=='physical' else float(smooth((r-.76)/.24))
                cy=fitted*(1-fade)+cy*fade
            closedverts.append((x,cy,nz))
            if TRANSFER_NORMALS:
                base_normals[idx]=normal_lookup[idx]
                target_normals[idx]=target_normal(x,nz,math.hypot((x-cx)/RX,(nz-cz)/RZ) if os.environ.get('BLINK_WARP')=='physical' else r)
                vertex_sides[idx]=side
        rings.append(ids)
    center=len(allverts);y,rgb=sample(cx,cz)
    local=[sample(cx+dx,cz+dz)[0] for dx,dz in ((-.004,0),(.004,0),(0,-.004),(0,.004))]
    y=.5*y+.125*sum(local)
    center_y=coeff@np.asarray((1,0,.009,0,0,.009*.009)) if os.environ.get('BLINK_CLOSED_SURFACE')=='smooth' else sample(cx,cz+.009)[0]
    allverts.append((cx,y,cz));closedverts.append((cx,center_y,cz+.009));color_lookup[center]=rgb;new_indices.append(center)
    if TRANSFER_NORMALS:
        normal_lookup[center]=sample(cx,cz,True)[2]
        base_normals[center]=normal_lookup[center]
        target_normals[center]=target_normal(cx,cz+.009,0)
        vertex_sides[center]=side
    newfaces=[];count=len(order)*SUBDIV
    # Bridge dense interior to the exact original boundary without adding an
    # overlapping surface or changing neighboring source faces.
    for i in range(len(order)):
        a,b=order[i],order[(i+1)%len(order)]
        for k in range(SUBDIV):
            j=i*SUBDIV+k
            newfaces.append((a,rings[0][(j+1)%count],rings[0][j]))
        newfaces.append((a,b,rings[0][((i+1)*SUBDIV)%count]))
    for outer,inner in zip(rings,rings[1:]):
        for i in range(count):newfaces.append((outer[i],outer[(i+1)%count],inner[(i+1)%count],inner[i]))
    for i in range(count):newfaces.append((rings[-1][i],rings[-1][(i+1)%count],center))
    for face in newfaces:
        allfaces.append(face);face_uv.append([(0,0)]*len(face));face_colors.append([(*color_lookup[i],1) for i in face]);face_smooth.append(True);face_normals.append([tuple(normal_lookup[i]) if i in normal_lookup else (0,0,0) for i in face])
        is_highlight=any(min(color_lookup[i])>.025 and abs(allverts[i][0]-cx)<.09 and abs(allverts[i][2]-cz)<.09 for i in face)
        face_mats.append(base_idx+int(is_highlight))
    patches.append((side,new_indices,highlight))
    stats[side]={'removedFaces':len(selected),'boundaryVertices':len(order),'newVertices':len(new_indices)}

for p in mesh.polygons:
    if p.index in removed:continue
    allfaces.append(tuple(p.vertices));face_mats.append(0);face_smooth.append(p.use_smooth)
    face_uv.append([tuple(mesh.uv_layers[0].data[i].uv) for i in p.loop_indices]);face_colors.append([(1,1,1,1)]*len(p.vertices))
    face_normals.append([(0,0,0) if mesh.loops[i].vertex_index in boundaries else tuple(original_normals[i]) for i in p.loop_indices])

new=bpy.data.meshes.new('Stitched eyes and original body');new.from_pydata(allverts,[],allfaces);new.update()
for m in materials:new.materials.append(m)
uv=new.uv_layers.new(name=mesh.uv_layers[0].name)
colors=new.color_attributes.new(name='SourceColor',type='FLOAT_COLOR',domain='CORNER')
normals=[]
for p,uvs,cols,mi,smooth_flag,norms in zip(new.polygons,face_uv,face_colors,face_mats,face_smooth,face_normals):
    p.material_index=mi;p.use_smooth=smooth_flag
    for loop_index,tex,col in zip(p.loop_indices,uvs,cols):uv.data[loop_index].uv=tex;colors.data[loop_index].color=col
    normals.extend(norms)
new.normals_split_custom_set(normals);new.color_attributes.active_color=colors
weights=[[(g.group,g.weight) for g in v.groups] for v in mesh.vertices]
group_names=[g.name for g in body.vertex_groups]
body.data=new
for name in group_names:
    if body.vertex_groups.get(name) is None:body.vertex_groups.new(name=name)
for i,influences in enumerate(weights):
    for group,weight in influences:body.vertex_groups[group].add([i],weight,'REPLACE')
head=body.vertex_groups.get('J_Bip_C_Head')
head.add(list(range(len(points),len(allverts))),1,'REPLACE')
body.shape_key_add(name='Basis');keys=[]
for side,indices,highlight in patches:
    key=body.shape_key_add(name=f'Close{side}');keys.append(key)
    for index in indices:key.data[index].co=closedverts[index]
    for name in ('blink','blink_left' if side=='L' else 'blink_right'):
        expr=getattr(arm.data.vrm_addon_extension.vrm1.expressions.preset,name)
        bind=expr.morph_target_binds.add();bind.node.mesh_object_name=body.name;bind.index=key.name;bind.weight=1
        cb=expr.material_color_binds.add();cb.material=highlight;cb.type='color';cb.target_value=(.004,.004,.004,1)
for weight in (0,.25,.5,.75,1):
    for key in keys:key.value=weight
    for _,tint,_ in tints:tint.inputs[6].default_value=(1-.996*weight,)*3+(1,)
    if MORPH_NORMALS:
        bpy.context.view_layer.update()
        evaluated=body.evaluated_get(bpy.context.evaluated_depsgraph_get())
        snapshot_mesh=bpy.data.meshes.new_from_object(evaluated)
        snapshot=bpy.data.objects.new('Normal interpolation preview',snapshot_mesh)
        bpy.context.collection.objects.link(snapshot);snapshot.matrix_world=body.matrix_world
        dynamic=[]
        for loop in snapshot_mesh.loops:
            i=loop.vertex_index
            dynamic.append(tuple((base_normals[i]*(1-weight)+target_normals[i]*weight).normalized()) if i in base_normals else tuple(snapshot_mesh.corner_normals[loop.index].vector))
        snapshot_mesh.normals_split_custom_set(dynamic);body.hide_render=True
        for angle in views:render(f'wipe-{weight:g}',angle)
        body.hide_render=False;bpy.data.objects.remove(snapshot,do_unlink=True);bpy.data.meshes.remove(snapshot_mesh)
    else:
        for angle in views:render(f'wipe-{weight:g}',angle)
for key in keys:key.value=0
for _,tint,_ in tints:tint.inputs[6].default_value=(1,1,1,1)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(OUT/'continuous-blink.vrm'))
if MORPH_NORMALS:
    (OUT/'before-normal-patch.vrm').write_bytes((OUT/'continuous-blink.vrm').read_bytes())
    indices=sorted(base_normals)
    np.savez(OUT/'morph-normals.npz',positions=np.asarray([allverts[i] for i in indices]),base=np.asarray([base_normals[i] for i in indices]),target=np.asarray([target_normals[i] for i in indices]),side=np.asarray([0 if vertex_sides[i]=='L' else 1 for i in indices]))
report={'method':'stitched-local-retopo-squint','blender':bpy.app.version_string,'warp':os.environ.get('BLINK_WARP','ring'),'closedSurface':os.environ.get('BLINK_CLOSED_SURFACE','source'),'normalTransfer':os.environ.get('BLINK_NORMALS','none'),'rings':RINGS,'angularSubdivisions':SUBDIV,'radius':[RX,RZ],'eyes':stats,'export':sorted(result),'scriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n');print('STITCHED',json.dumps(report))
