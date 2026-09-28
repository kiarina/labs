"""Retract four vowel targets behind source lip ink, preserving Basis and AA."""
import hashlib
import json
import os
from pathlib import Path
import struct
import sys

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'scripts'))
from source_ink import SourceInk

SOURCE=ROOT/'artifacts/mouth-onset-recessed'
OUT=ROOT/'artifacts'/os.environ.get('MOUTH_RUN','mouth-full-recessed')
if OUT.name in ('mouth-onset-recessed','mouth-profile-fitted','mouth-vowels-flatstart','overlay-selected-plus','continuous-fresh','mouth-red-bound'):
    raise ValueError('Preserve approved input and comparison artifacts')
OUT.mkdir(exist_ok=True)
settings=json.loads((SOURCE/'report.json').read_text())
curve=np.asarray(json.loads((ROOT/'artifacts/mouth-red-bound/report.json').read_text())['curve'])
xs=np.linspace(-.076,.076,161)
bpy.ops.wm.open_mainfile(filepath=str(SOURCE/'continuous-blink.blend'))
body=bpy.data.objects['Miineko_Body'];mouth=bpy.data.objects['Mouth_Cartoon']
body.data.calc_loop_triangles();mouth.data.calc_loop_triangles()
head=BVHTree.FromPolygons([v.co.copy() for v in body.data.vertices],[list(t.vertices) for t in body.data.loop_triangles],all_triangles=True)
ink=SourceInk(body,head)
def face_y(x,z):
    hit=head.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))[0]
    if hit is None:raise ValueError('Depth ray misses head')
    return hit.y
keys=mouth.data.shape_keys.key_blocks
names=('aa','ih','ou','ee','oh');modified=('ih','ou','ee','oh')
base=np.asarray([p.co for p in keys['Basis'].data])
old={n:np.asarray([p.co for p in keys[n.upper()].data]) for n in names}
targets={n:p.copy() for n,p in old.items()}
for name in modified:
    for i,(x,y,z) in enumerate(targets[name]):
        surface,dark=ink.sample(float(x),float(z))
        if dark:
            z1=float(np.interp(x,xs,curve[:,2]))-.006;z2=z1-.015
            y1,y2=face_y(float(x),z1),face_y(float(x),z2)
            surface=max(surface,y1+(z-z1)*(y1-y2)/(z1-z2))
        targets[name][i,1]=max(y,surface-.0008)

tri=np.asarray([list(t.vertices) for t in mouth.data.loop_triangles])
uv=np.zeros((len(base),2))
for loop in mouth.data.loops:uv[loop.vertex_index]=mouth.data.uv_layers[0].data[loop.index].uv
states=[{n:w} for n in modified for w in (.05,.1,.18,.22,.35,.5,.75,1)]
for i,a in enumerate(names):
    for b in names[i+1:]:
        states += [{a:.5,b:.5},{a:.25,b:.25}]
states += [dict.fromkeys(names,.2),dict.fromkeys(names,.1),dict.fromkeys(names,.036)]
constraints=[]
for mix in states:
    total=sum(mix.values());old_points=(1-total)*base.copy()
    for name,w in mix.items():old_points+=w*old[name]
    valid=np.linalg.norm(np.cross(old_points[tri[:,1]]-old_points[tri[:,0]],old_points[tri[:,2]]-old_points[tri[:,0]]),axis=1)>2e-12
    for bary in ((1/3,1/3,1/3),(.6,.2,.2),(.2,.6,.2),(.2,.2,.6)):
        visible=valid&(np.einsum('tvc,v->tc',uv[tri],bary)[:,1]+.65*total>.501)
        ids=tri[visible];samples=np.einsum('tvc,v->tc',old_points[ids],bary)
        source=[ink.sample(float(x),float(z)) for x,y,z in samples]
        keep=np.asarray([not dark for y,dark in source],dtype=bool)
        ids=ids[keep];samples=samples[keep]
        bound=np.maximum(samples[:,1],np.asarray([y for y,dark in source])[keep]-.0008)
        constraints.append((mix,ids,np.asarray(bary),bound))

solver_steps=int(os.environ.get('VOWEL_SOLVER_STEPS','64'))
for _ in range(solver_steps):
    push={n:np.zeros(len(base)) for n in modified}
    for mix,ids,bary,bound in constraints:
        y=(1-sum(mix.values()))*base[:,1]
        for name,w in mix.items():y=y+w*targets[name][:,1]
        active_weight=sum(w for n,w in mix.items() if n in modified)
        error=np.maximum(0,np.einsum('tv,v->t',y[ids],bary)-bound)/active_weight
        for name in modified:
            if mix.get(name,0)>0:np.maximum.at(push[name],ids.ravel(),np.repeat(error,3))
    for name in modified:targets[name][:,1]=np.maximum(old[name][:,1],targets[name][:,1]-push[name])
fallback={n:set() for n in modified}
for mix,ids,bary,bound in constraints:
    y=(1-sum(mix.values()))*base[:,1]
    for name,w in mix.items():y=y+w*targets[name][:,1]
    bad=np.einsum('tv,v->t',y[ids],bary)>bound+1e-7
    for name in modified:
        if mix.get(name,0)>0:fallback[name].update(ids[bad].ravel().tolist())
for name in modified:
    if fallback[name]:
        ids=np.asarray(sorted(fallback[name]));targets[name][ids,1]=old[name][ids,1]
    grid=targets[name].reshape(17,161,3);collapsed=np.ptp(grid[:,:,2],axis=0)<1e-7
    grid[:,collapsed,1]=grid[:,collapsed,1].min(axis=0)
    for p,co in zip(keys[name.upper()].data,targets[name]):p.co=co
assert np.array_equal(base,np.asarray([p.co for p in keys['Basis'].data]))
assert np.array_equal(old['aa'],np.asarray([p.co for p in keys['AA'].data]))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(OUT/'continuous-blink.vrm'))
# Preserve the existing standard no-mipmap mouth sampler after Blender export.
path=OUT/'continuous-blink.vrm';raw=path.read_bytes();length=struct.unpack_from('<I',raw,12)[0]
doc=json.loads(raw[20:20+length]);tail=raw[20+length:]
material=next(m for m in doc['materials'] if m['name']=='Cartoon mouth single palette')
texture=doc['textures'][material['pbrMetallicRoughness']['baseColorTexture']['index']]
sampler=dict(doc['samplers'][texture['sampler']]);sampler.update(minFilter=9729,magFilter=9729)
texture['sampler']=len(doc['samplers']);doc['samplers'].append(sampler)
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
path.write_bytes(struct.pack('<4sII',b'glTF',2,20+len(encoded)+len(tail))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+tail)
report={'method':'four-vowel-depth-under-source-ink','flatStart':settings['flatStart'],'source':SOURCE.name,'sourceVrmSha256':hashlib.sha256((SOURCE/'continuous-blink.vrm').read_bytes()).hexdigest(),'scriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'states':len(states),'solverSteps':solver_steps,'basisAndAaUnchanged':True,'targets':{n:{'maximumRetraction':float((targets[n][:,1]-old[n][:,1]).max()),'fallbackVertices':len(fallback[n])} for n in modified},'driverConstraint':'nonnegative weights with sum <= 1','export':sorted(result)}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
