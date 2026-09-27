"""Extend a red cartoon opening with four distinct, compatible vowel targets.

Columns keep their source X positions. Narrow vowels collapse unused columns
instead of sliding the opening across the source W rim. All targets share the
same collapsed neutral state. Speech-driven use should normalize vowel weights
so their sum does not exceed one; that is a driver contract, not a VRM constraint.
"""
import hashlib
import json
import math
import os
import struct
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'artifacts'/os.environ.get('VOWEL_INPUT','mouth-red-bound')
OUT=ROOT/'artifacts'/os.environ.get('MOUTH_RUN','mouth-red-vowels')
protected=[SOURCE,ROOT/'artifacts/continuous-fresh',ROOT/'artifacts/overlay-selected-plus']
if OUT.resolve() in [p.resolve() for p in protected]:raise ValueError('Preserve selected inputs')
OUT.mkdir(exist_ok=True)
settings=json.loads((SOURCE/'report.json').read_text())
assert settings['style']=='red-panel' and settings['surfaceBind']=='opening'
bpy.ops.wm.open_mainfile(filepath=str(SOURCE/'continuous-blink.blend'))
body=bpy.data.objects['Miineko_Body'];arm=bpy.data.objects['Miineko_Rig']
mouth=bpy.data.objects['Mouth_Cartoon'];red=bpy.data.objects['Mouth_Pink_Accent']
assert len(mouth.data.vertices)==161*17 and len(red.data.vertices)==161*33
body.data.calc_loop_triangles()
head=BVHTree.FromPolygons([v.co.copy() for v in body.data.vertices],[list(t.vertices) for t in body.data.loop_triangles],all_triangles=True)
mouth.data.calc_loop_triangles()
topology=[list(t.vertices) for t in mouth.data.loop_triangles]
curve=np.asarray(settings['curve']);source_width=settings['width']
xs=np.linspace(-source_width,source_width,len(curve))
presets={'ih':(.076,.442),'ou':(.038,.421),'ee':(.068,.432),'oh':(.048,.404)}
exprs=arm.data.vrm_addon_extension.vrm1.expressions.preset

def limits(x,width,floor):
    top=float(np.interp(x,xs,curve[:,0]))
    if abs(x)>=width:return top,top
    taper=1-(x/width)**2
    bottom=min(top-.003*taper,floor+(.479-floor)*(x/width)**2)
    return top,bottom

def face_y(x,z):
    hit=head.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))[0]
    if hit is None:raise ValueError('Vowel target misses head')
    return hit.y

for name,(width,floor) in presets.items():
    coords=[]
    for i,v in enumerate(mouth.data.vertices):
        x=v.co.x;t=(i//161)/16
        top,bottom=limits(x,width,floor);z=top+(bottom-top)*t
        # Unused columns are exactly collapsed in all three coordinates.
        y=face_y(x,z)+.0003-.0013*t if bottom<top else face_y(x,z)+.0003
        coords.append((x,y,z))
    key=mouth.shape_key_add(name=name.upper())
    for i,co in enumerate(coords):key.data[i].co=co
    target_bvh=BVHTree.FromPolygons([Vector(p) for p in coords],topology,all_triangles=True)
    red_key=red.shape_key_add(name=name.upper())
    red_width=.067*(width/source_width)
    for i,v in enumerate(red.data.vertices):
        x=v.co.x
        span=.86*math.sqrt(max(0,1-(x/red_width)**2))
        t=.52+span*((i//161)/32-.5)
        top,bottom=limits(x,width,floor);z=top+(bottom-top)*t
        hit=target_bvh.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))[0]
        y=hit.y if hit is not None else face_y(x,z)+.0003
        red_key.data[i].co=(x,y-.0008,z)
    expr=getattr(exprs,name)
    expr.morph_target_binds.clear();expr.texture_transform_binds.clear();expr.material_color_binds.clear()
    expr.is_binary=False
    for template in exprs.aa.morph_target_binds:
        bind=expr.morph_target_binds.add();bind.node.mesh_object_name=template.node.mesh_object_name
        bind.index=name.upper() if template.node.mesh_object_name.startswith('Mouth_') else template.index
        bind.weight=template.weight

single_surface=os.environ.get('MOUTH_SINGLE_SURFACE')=='1'
if single_surface:
    # One surface keeps the red field and black outline together during every
    # vowel blend. A separate inset can intersect while two shapes cross-fade.
    for name in ('aa','ih','ou','ee','oh'):
        bindings=getattr(exprs,name).morph_target_binds
        for i in reversed(range(len(bindings))):
            if bindings[i].node.mesh_object_name==red.name:bindings.remove(i)
    bpy.data.objects.remove(red,do_unlink=True)
    colors=mouth.data.color_attributes.new(name='MouthPalette',type='FLOAT_COLOR',domain='CORNER')
    def smooth(t):
        t=max(0,min(1,t));return t*t*(3-2*t)
    for loop in mouth.data.loops:
        t=(loop.vertex_index//161)/16
        mix=smooth((t-.03)/.045)*(1-smooth((t-.93)/.045))
        black=np.asarray((.002,.0007,.0015));fill=np.asarray((.52,.003,.015))
        colors.data[loop.index].color=(*(black*(1-mix)+fill*mix),1)
    mouth.data.color_attributes.active_color=colors
    material=bpy.data.materials.new('Cartoon mouth single palette');material.use_nodes=True
    nodes,links=material.node_tree.nodes,material.node_tree.links;nodes.clear()
    color=nodes.new('ShaderNodeVertexColor');color.layer_name='MouthPalette'
    output=nodes.new('ShaderNodeOutputMaterial')
    # Blender's glTF exporter recognizes RGBA directly feeding the output as
    # KHR_materials_unlit. This is a standard exported material, not a viewer hack.
    links.new(color.outputs['Color'],output.inputs['Surface'])
    mouth.data.materials.clear();mouth.data.materials.append(material)

flat_start=os.environ.get('MOUTH_FLAT_START')=='1'
flat_report=None
if flat_start:
    assert single_surface, 'Flat onset requires the single mouth surface'
    # A collapsed W basis necessarily leaves a central peak at intermediate
    # morph weights. Start from an invisible, shallow opening instead, with a
    # flat central floor. A standard VRM UV reveal hides it exactly at neutral.
    floors={'Basis':.438,'AA':settings['floor'],'IH':.435,'OU':.421,'EE':.428,'OH':.404}
    widths={'Basis':source_width,'AA':source_width,**{n.upper():p[0] for n,p in presets.items()}}
    for key in mouth.data.shape_keys.key_blocks:
        floor=floors[key.name];width=widths[key.name]
        for i,point in enumerate(key.data):
            x=float(xs[i%161]);t=(i//161)/16
            top=float(np.interp(x,xs,curve[:,0]))
            bottom=top if abs(x)>=width else min(top-.0001,floor+(.479-floor)*(x/width)**4)
            point.co.z=top+(bottom-top)*t
    for i,point in enumerate(mouth.data.vertices):point.co=mouth.data.shape_keys.key_blocks['Basis'].data[i].co
    shift=.65;reveal_end=.12;z_start=.485;z_end=.430
    uv=mouth.data.uv_layers.new(name='FlatOpeningReveal')
    for loop in mouth.data.loops:
        z=mouth.data.vertices[loop.vertex_index].co.z
        uv.data[loop.index].uv=((loop.vertex_index//161)/16,.5+(z-z_start)*shift*reveal_end/(z_start-z_end))
    height=4096;vv=(np.arange(height)+.5)/height
    alpha=np.clip((vv-.5)/.001,0,1);alpha=alpha*alpha*(3-2*alpha)
    palette_width=256;uu=(np.arange(palette_width)+.5)/palette_width
    palette=np.asarray([smooth((u-.03)/.045)*(1-smooth((u-.93)/.045)) for u in uu])
    rgb=np.asarray((.002,.0007,.0015))[None,:]*(1-palette[:,None])+np.asarray((.52,.003,.015))[None,:]*palette[:,None]
    rgb=np.where(rgb<=.0031308,12.92*rgb,1.055*rgb**(1/2.4)-.055)
    rgba=np.ones((height,palette_width,4),np.float32);rgba[:,:,:3]=rgb[None,:,:];rgba[:,:,3]=alpha[:,None]
    ramp=bpy.data.images.new('Mouth onset reveal',width=palette_width,height=height,alpha=True)
    ramp.pixels.foreach_set(rgba.ravel());ramp.filepath_raw=str(OUT/'mouth-reveal.png');ramp.file_format='PNG';ramp.save()
    ramp=bpy.data.images.load(ramp.filepath_raw,check_existing=False);ramp.pack()
    material.surface_render_method='BLENDED';material.use_backface_culling=False
    coord=nodes.new('ShaderNodeTexCoord');mapping=nodes.new('ShaderNodeMapping');mapping.vector_type='POINT'
    tex=nodes.new('ShaderNodeTexImage');tex.image=ramp;tex.extension='EXTEND'
    links.new(coord.outputs['UV'],mapping.inputs['Vector']);links.new(mapping.outputs['Vector'],tex.inputs['Vector'])
    transparent=nodes.new('ShaderNodeBsdfTransparent');mix=nodes.new('ShaderNodeMixShader')
    links.new(tex.outputs['Alpha'],mix.inputs[0]);links.new(transparent.outputs[0],mix.inputs[1])
    links.new(tex.outputs['Color'],mix.inputs[2]);links.new(mix.outputs[0],output.inputs['Surface'])
    mouth.data.color_attributes.remove(colors);nodes.remove(color)
    for name in ('aa','ih','ou','ee','oh'):
        bind=getattr(exprs,name).texture_transform_binds.add();bind.material=material;bind.scale=(1,1);bind.offset=(0,-shift)
    flat_report={'basisFloor':floors['Basis'],'floors':floors,'profilePower':4,'uvShift':shift,'revealEnd':reveal_end,'neutralVisibility':'zero texture alpha; nondegenerate geometry'}

envelope_report=None
envelope_mode=os.environ.get('MOUTH_ENVELOPE')
if envelope_mode in ('linear','linear-local','linear-vertex'):
    assert single_surface,'Envelope probe currently targets the single surface'
    # A per-column affine depth field is preserved exactly by linear morph
    # interpolation, including mixtures. Fit it in front of the source face,
    # instead of letting chords between sampled curved surfaces cut through it.
    coefficients=[];max_gap=0.;min_gap=1.
    clearance=float(os.environ.get('MOUTH_CLEARANCE','.001'))
    per_vertex=envelope_mode=='linear-vertex'
    keys=list(mouth.data.shape_keys.key_blocks)
    key_z=np.asarray([[p.co.z for p in key.data] for key in keys])
    for column in range(len(mouth.data.vertices) if per_vertex else len(xs)):
        x=xs[column%161]
        top=float(np.interp(x,xs,curve[:,0]));bottom=.400
        if envelope_mode in ('linear-local','linear-vertex'):
            used=key_z[:,column] if per_vertex else key_z[:,column::161]
            bottom,top=float(used.min()),float(used.max())
        zs=np.linspace(bottom,top,241)
        ys=np.asarray([face_y(float(x),float(z)) for z in zs])
        A=np.stack([np.ones_like(zs),zs-.45],axis=-1)
        c=np.linalg.lstsq(A,ys,rcond=None)[0]
        c[0]-=max(0,float((A@c-ys).max()))+clearance
        gaps=ys-A@c;max_gap=max(max_gap,float(gaps.max()));min_gap=min(min_gap,float(gaps.min()))
        coefficients.append(c)
    for key in mouth.data.shape_keys.key_blocks:
        for i,point in enumerate(key.data):
            c=coefficients[i if per_vertex else i%161]
            point.co.y=c[0]+c[1]*(point.co.z-.45)
    for i,point in enumerate(mouth.data.vertices):
        c=coefficients[i if per_vertex else i%161];point.co.y=c[0]+c[1]*(point.co.z-.45)
    envelope_report={'mode':envelope_mode,'sampledMinimumClearance':min_gap,'sampledMaximumForwardDistance':max_gap,'samplesPerFit':241,'fitCount':len(coefficients),'range':'actual morph range per vertex' if per_vertex else ('actual morph range per column' if envelope_mode=='linear-local' else '0.400 to source lip')}
    smoothing=int(os.environ.get('MOUTH_DEPTH_SMOOTH','0'))
    if smoothing:
        for key in keys:
            ys=np.asarray([p.co.y for p in key.data]).reshape(17,161)
            for _ in range(smoothing):
                averaged=ys.copy();averaged[:,1:-1]=.25*ys[:,:-2]+.5*ys[:,1:-1]+.25*ys[:,2:]
                ys=np.minimum(ys,averaged)
            for point,y in zip(key.data,ys.ravel()):point.co.y=y
        for i,point in enumerate(mouth.data.vertices):point.co=keys[0].data[i].co
        envelope_report['forwardOnlySmoothingPasses']=smoothing
        envelope_report['measurementScope']='per-vertex fits before forward-only smoothing'
    if os.environ.get('MOUTH_TRIANGLE_CLEARANCE')=='1':
        assert flat_start and per_vertex
        # Vertex fits do not bound triangle interiors against the irregular
        # source lips. Push affected vertices forward for sampled visible
        # barycentric points, using one shared correction for every target.
        tri=np.asarray(topology);uv=np.zeros((len(mouth.data.vertices),2))
        for loop in mouth.data.loops:uv[loop.vertex_index]=mouth.data.uv_layers[0].data[loop.index].uv
        base=np.asarray([p.co for p in keys[0].data])
        deltas={name:np.asarray([p.co for p in mouth.data.shape_keys.key_blocks[name.upper()].data])-base for name in ('aa','ih','ou','ee','oh')}
        states=[{name:w} for name in deltas for w in (.02,.05,.1,.22,.5,.75,1)]
        states += [{'aa':.5,'ih':.5},{'ou':.5,'oh':.5},dict.fromkeys(deltas,.2)]
        push=np.zeros(len(base));sample_count=0
        for mix in states:
            points=base.copy()
            for name,w in mix.items():points+=w*deltas[name]
            triangles=points[tri]
            valid=np.linalg.norm(np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]),axis=1)>2e-12
            for bary in ((1/3,1/3,1/3),(.6,.2,.2),(.2,.6,.2),(.2,.2,.6)):
                active=valid & (np.einsum('tvc,v->tc',uv[tri],bary)[:,1]+.65*sum(mix.values())>.501)
                samples=np.einsum('tvc,v->tc',triangles[active],bary)
                required=np.asarray([max(0,y-face_y(float(x),float(z))+.0008) for x,y,z in samples])
                np.maximum.at(push,tri[active].ravel(),np.repeat(required,3));sample_count+=len(samples)
        grid=push.reshape(17,161)
        for _ in range(8):
            average=grid.copy();average[:,1:-1]=.25*grid[:,:-2]+.5*grid[:,1:-1]+.25*grid[:,2:]
            grid=np.maximum(grid,average)
        push=grid.ravel()
        for key in keys:
            for p,d in zip(key.data,push):p.co.y-=d
        for i,p in enumerate(mouth.data.vertices):p.co=keys[0].data[i].co
        envelope_report['triangleCorrection']={'states':len(states),'samples':sample_count,'maximumForwardCorrection':float(push.max()),'targetClearance':.0008,'scope':'four barycentric samples per visible triangle; sampled states only'}
    if per_vertex:
        # Narrow vowels collapse unused columns. Different per-vertex depth
        # fits must not turn a collapsed line into a horizontal colored shelf.
        pinned=0
        for key in keys:
            coords=np.asarray([p.co for p in key.data]).reshape(17,161,3)
            collapsed=np.ptp(coords[:,:,2],axis=0)<1e-7
            coords[:,collapsed,1]=coords[:,collapsed,1].min(axis=0)
            pinned+=int(collapsed.sum())
            for p,co in zip(key.data,coords.reshape(-1,3)):p.co=co
        for i,p in enumerate(mouth.data.vertices):p.co=keys[0].data[i].co
        envelope_report['collapsedColumnsPinned']=pinned

bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(OUT/'continuous-blink.vrm'))
if flat_start:
    # The exporter always requests mipmaps for linear image nodes. Near the
    # narrow mouth corners those mipmaps leak alpha across the neutral cutoff.
    # Use the standard glTF non-mipmapped LINEAR sampler for this texture only.
    path=OUT/'continuous-blink.vrm';raw=path.read_bytes();length=struct.unpack_from('<I',raw,12)[0]
    document=json.loads(raw[20:20+length]);tail=raw[20+length:]
    mouth_material=next(m for m in document['materials'] if m['name']==material.name)
    texture=document['textures'][mouth_material['pbrMetallicRoughness']['baseColorTexture']['index']]
    sampler=dict(document['samplers'][texture['sampler']]);sampler.update(minFilter=9729,magFilter=9729)
    texture['sampler']=len(document['samplers']);document['samplers'].append(sampler)
    encoded=json.dumps(document,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
    path.write_bytes(struct.pack('<4sII',b'glTF',2,20+len(encoded)+len(tail))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+tail)
    flat_report['vrmSampler']='LINEAR without mipmaps; neutral alpha bleed prevention'
report={'method':'five-cartoon-vowel-targets','singleSurface':single_surface,'flatStart':flat_report,'linearEnvelope':envelope_report,'source':SOURCE.name,'sourceVrmSha256':hashlib.sha256((SOURCE/'continuous-blink.vrm').read_bytes()).hexdigest(),'sourceBlendSha256':hashlib.sha256((SOURCE/'continuous-blink.blend').read_bytes()).hexdigest(),'scriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'vowels':{name:[width,floors[name.upper()] if flat_start else floor] for name,(width,floor) in {'aa':(source_width,settings['floor']),**presets}.items()},'driverConstraint':'nonnegative weights with sum <= 1','export':sorted(result)}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
