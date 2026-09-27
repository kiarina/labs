"""Measure sampled visible triangle clearance, not merely fitted vertex lines."""
import json
import os
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

root=Path(__file__).resolve().parents[1]
folder=root/'artifacts'/os.environ['SURFACE_RUN']
bpy.ops.wm.open_mainfile(filepath=str(folder/'continuous-blink.blend'))
mouth=bpy.data.objects['Mouth_Cartoon'];body=bpy.data.objects['Miineko_Body']
body.data.calc_loop_triangles();mouth.data.calc_loop_triangles()
head=BVHTree.FromPolygons([v.co.copy() for v in body.data.vertices],
    [list(t.vertices) for t in body.data.loop_triangles],all_triangles=True)
ink=None
if os.environ.get('MEASURE_SOURCE_INK')=='1':
    sys.path.insert(0,str(root/'scripts'))
    from source_ink import SourceInk
    ink=SourceInk(body,head)
tri=np.asarray([list(t.vertices) for t in mouth.data.loop_triangles])
uv=np.zeros((len(mouth.data.vertices),2))
for loop in mouth.data.loops:uv[loop.vertex_index]=mouth.data.uv_layers[0].data[loop.index].uv
uv_centers=uv[tri].mean(1)
keys=mouth.data.shape_keys.key_blocks
base=np.asarray([p.co for p in keys['Basis'].data])
delta={name:np.asarray([p.co for p in keys[name.upper()].data])-base for name in ('aa','ih','ou','ee','oh')}
states=[{name:weight} for name in delta for weight in (.1,.18,.22,.5,1)]
states += [{'aa':.5,'ih':.5},{'ou':.5,'oh':.5},dict.fromkeys(delta,.2)]
states += [{'aa':.25,'ih':.25},{'ou':.25,'oh':.25},dict.fromkeys(delta,.1),dict.fromkeys(delta,.036)]
report={'scope':'visible triangle centroids at sampled states; not continuous collision proof','states':[]}
for mix in states:
    points=base.copy()
    for name,weight in mix.items():points+=weight*delta[name]
    triangles=points[tri];centers=triangles.mean(1)
    areas=np.linalg.norm(np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]),axis=1)/2
    visible=(uv_centers[:,1]+.65*sum(mix.values())>.501)&(areas>1e-12)
    gaps=[];dark=[]
    for x,y,z in centers[visible]:
        hit=head.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))[0]
        if hit is None:raise ValueError('Mouth sample misses source head')
        gaps.append(hit.y-y)
        if ink:dark.append(ink.sample(float(x),float(z))[1])
    gaps=np.asarray(gaps)
    report['states'].append({'weights':mix,'samples':len(gaps),'minimum':float(gaps.min()),
        'median':float(np.median(gaps)),'p95':float(np.percentile(gaps,95)),
        'maximum':float(gaps.max()),'behindHeadCount':int((gaps<0).sum())})
    if ink:
        dark=np.asarray(dark);skin=gaps[~dark]
        report['states'][-1].update(nonInkMinimum=float(skin.min()) if len(skin) else None,
            nonInkBehindHeadCount=int((skin<0).sum()),inkOccludedCount=int(((gaps<0)&dark).sum()))
(folder/'surface-measurements.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'run':folder.name,'states':len(report['states']),
    'worstPenetration':min(s['minimum'] for s in report['states']),
    'largestP95Gap':max(s['p95'] for s in report['states'])}))
