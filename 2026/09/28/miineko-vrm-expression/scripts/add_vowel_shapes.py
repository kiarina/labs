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

envelope_report=None
envelope_mode=os.environ.get('MOUTH_ENVELOPE')
if envelope_mode in ('linear','linear-local'):
    assert single_surface,'Envelope probe currently targets the single surface'
    # A per-column affine depth field is preserved exactly by linear morph
    # interpolation, including mixtures. Fit it in front of the source face,
    # instead of letting chords between sampled curved surfaces cut through it.
    coefficients=[];max_gap=0.;min_gap=1.
    for column,x in enumerate(xs):
        top=float(np.interp(x,xs,curve[:,0]));bottom=.400
        if envelope_mode=='linear-local':
            used=[p.co.z for key in mouth.data.shape_keys.key_blocks for p in list(key.data)[column::161]]
            bottom,top=min(used),max(used)
        zs=np.linspace(bottom,top,241)
        ys=np.asarray([face_y(float(x),float(z)) for z in zs])
        A=np.stack([np.ones_like(zs),zs-.45],axis=-1)
        c=np.linalg.lstsq(A,ys,rcond=None)[0]
        c[0]-=max(0,float((A@c-ys).max()))+.001
        gaps=ys-A@c;max_gap=max(max_gap,float(gaps.max()));min_gap=min(min_gap,float(gaps.min()))
        coefficients.append(c)
    for key in mouth.data.shape_keys.key_blocks:
        for i,point in enumerate(key.data):
            c=coefficients[i%161]
            point.co.y=c[0]+c[1]*(point.co.z-.45)
    for i,point in enumerate(mouth.data.vertices):
        c=coefficients[i%161];point.co.y=c[0]+c[1]*(point.co.z-.45)
    envelope_report={'mode':envelope_mode,'sampledMinimumClearance':min_gap,'sampledMaximumForwardDistance':max_gap,'samplesPerColumn':241,'range':'actual morph range per column' if envelope_mode=='linear-local' else '0.400 to source lip'}

bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(OUT/'continuous-blink.vrm'))
report={'method':'five-cartoon-vowel-targets','singleSurface':single_surface,'linearEnvelope':envelope_report,'source':SOURCE.name,'sourceVrmSha256':hashlib.sha256((SOURCE/'continuous-blink.vrm').read_bytes()).hexdigest(),'sourceBlendSha256':hashlib.sha256((SOURCE/'continuous-blink.blend').read_bytes()).hexdigest(),'scriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'vowels':{'aa':[source_width,settings['floor']],**presets},'driverConstraint':'nonnegative weights with sum <= 1','export':sorted(result)}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
