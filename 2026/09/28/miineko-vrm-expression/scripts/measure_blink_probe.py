"""Measure exported attributes and neutral differences; does not judge aesthetics."""
import argparse
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image

parser=argparse.ArgumentParser()
parser.add_argument('run')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
folder=root/'artifacts'/args.run
raw=(folder/'continuous-blink.vrm').read_bytes()
size=struct.unpack_from('<I',raw,12)[0]
gltf=json.loads(raw[20:20+size])
binary=raw[28+size:]

def accessor(index):
    a=gltf['accessors'][index];v=gltf['bufferViews'][a['bufferView']]
    dtype={5121:'u1',5123:'<u2',5125:'<u4',5126:'<f4'}[a['componentType']]
    count={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4}[a['type']]
    array=np.ndarray((a['count'],count),dtype=dtype,buffer=binary,
                     offset=v.get('byteOffset',0)+a.get('byteOffset',0),
                     strides=(v.get('byteStride',np.dtype(dtype).itemsize*count),np.dtype(dtype).itemsize))
    if a.get('normalized'):array=array.astype(float)/np.iinfo(dtype).max
    return array

report={'run':args.run,'colors':[],'neutral':[],'bindings':{},'visualAcceptance':'not granted'}
for mesh in gltf['meshes']:
    for p in mesh['primitives']:
        material=gltf['materials'][p['material']]['name']
        if not (mesh['name'].startswith(('Lid','Eye patch')) or material.startswith('Stitched eye')):continue
        if 'COLOR_0' not in p['attributes']:raise AssertionError('Missing COLOR_0')
        values=accessor(p['attributes']['COLOR_0'])
        report['colors'].append({'mesh':mesh['name'],'channels':values.shape[1],
                                  'min':values.min(0).tolist(),'max':values.max(0).tolist()})
        assert values.shape[1]==4 and values[:,3].max()>.99
        if mesh['name'].startswith(('Lid','Eye patch')):assert values[:,3].min()<.01
expressions=gltf['extensions']['VRMC_vrm']['expressions']['preset']
for name in ('blink','blinkLeft','blinkRight'):
    expr=expressions[name];assert not expr.get('isBinary',False)
    materials=[gltf['materials'][b['material']]['name'] for b in expr.get('textureTransformBinds',[])]
    nodes=[gltf['nodes'][b['node']]['name'] for b in expr.get('morphTargetBinds',[])]
    targets=[gltf['meshes'][gltf['nodes'][b['node']]['mesh']]['extras']['targetNames'][b['index']] for b in expr.get('morphTargetBinds',[])]
    report['bindings'][name]={'materials':materials,'nodes':nodes,'targets':targets}
    assert materials or nodes
    if name=='blinkLeft':assert all(' R ' not in m for m in materials)
    if name=='blinkRight':assert all(' L ' not in m for m in materials)
    if name=='blinkLeft':assert all(not t.endswith('R') for t in targets)
    if name=='blinkRight':assert all(not t.endswith('L') for t in targets)

def compare(a,b,label,angle):
    x=np.asarray(Image.open(a).convert('RGB')).astype(float)
    y=np.asarray(Image.open(b).convert('RGB')).astype(float)
    assert x.shape==y.shape
    delta=abs(x-y)
    return {'kind':label,'angle':angle,'meanAbsoluteRgb255':float(delta.mean()),
            'maxRgb255':float(delta.max()),'fractionPixelsAbove12':float(np.mean(delta.max(-1)>12))}

for angle in (0,45,90):
    if (folder/f'source-{angle}.png').exists():
        for name in ('material-split','wipe-0'):
            target=folder/f'{name}-{angle}.png'
            if target.exists():report['neutral'].append(compare(folder/f'source-{angle}.png',target,name,angle))
    if (folder/'viewer'/f'blink-0-{angle}.png').exists():
        report['neutral'].append(compare(folder/'viewer'/f'source-{angle}.png',folder/'viewer'/f'blink-0-{angle}.png','viewer',angle))
(folder/'measurements.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
