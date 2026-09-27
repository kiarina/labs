"""Persist structural and visual measurements of one cartoon mouth probe."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image

parser=argparse.ArgumentParser();parser.add_argument('run');args=parser.parse_args()
root=Path(__file__).resolve().parents[1];folder=root/'artifacts'/args.run
raw=(folder/'continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0]
doc=json.loads(raw[20:20+n]);blob=raw[28+n:]

def accessor(index):
    a=doc['accessors'][index];v=doc['bufferViews'][a['bufferView']]
    dtype={5121:'u1',5123:'<u2',5125:'<u4',5126:'<f4'}[a['componentType']]
    width={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4}[a['type']]
    values=np.ndarray((a['count'],width),dtype=dtype,buffer=blob,offset=v.get('byteOffset',0)+a.get('byteOffset',0),strides=(v.get('byteStride',np.dtype(dtype).itemsize*width),np.dtype(dtype).itemsize)).copy()
    if a.get('normalized'):values=values.astype(float)/np.iinfo(dtype).max
    return values

aa=doc['extensions']['VRMC_vrm']['expressions']['preset']['aa']
assert not aa.get('isBinary',False)
report={'run':args.run,'vrmSha256':hashlib.sha256(raw).hexdigest(),'meshes':[]}
for binding in aa['morphTargetBinds']:
    node=doc['nodes'][binding['node']];mesh=doc['meshes'][node['mesh']]
    assert node['name'].startswith('Mouth') and mesh['extras']['targetNames'][binding['index']]=='AA'
    skin=doc['skins'][node['skin']]
    for p in mesh['primitives']:
        pos=accessor(p['attributes']['POSITION']);tri=accessor(p['indices']).reshape(-1,3)
        area=np.linalg.norm(np.cross(pos[tri[:,1]]-pos[tri[:,0]],pos[tri[:,2]]-pos[tri[:,0]]),axis=1)*.5
        joints=accessor(p['attributes']['JOINTS_0']);weights=accessor(p['attributes']['WEIGHTS_0'])
        bone_names={doc['nodes'][skin['joints'][int(joints[i,j])]]['name'] for i,j in np.argwhere(weights>1e-6)}
        assert bone_names=={'J_Bip_C_Head'},bone_names
        assert float(area.max())<1e-12
        target=accessor(p['targets'][binding['index']]['POSITION'])
        assert np.max(np.linalg.norm(target,axis=1))>0
        report['meshes'].append({'name':node['name'],'vertices':len(pos),'triangles':len(tri),'neutralMaximumTriangleArea':float(area.max()),'bones':sorted(bone_names),'maximumDisplacement':float(np.linalg.norm(target,axis=1).max())})
view=json.loads((folder/'viewer/report.json').read_text())
report['viewer']={'errors':view['errors'],'warnings':view['warnings'],'mouthStates':len(view['mouthStates']),'zeroRestoration':view['mouthZeroRestoration'],'relaxedCompositionMaximumDifference':max(x['maxChannelDifference'] for x in view['relaxedComposition']),'headFollowing':view.get('headFollowing',[])}
assert not view['errors']
assert max(c['maxChannelDifference'] for c in view['mouthZeroRestoration'])<=2
counts=[]
for value in [0,.02,.05,.1,.25,.5,.75,1]:
    image=np.asarray(Image.open(folder/'viewer'/f'aa-{value}-0.png').convert('RGB'))
    h,w,_=image.shape;region=image[int(h*.665):int(h*.80),int(w/2-h*.105):int(w/2+h*.105)]
    counts.append({'weight':value,'darkPixels':int((region.max(-1)<40).sum())})
monotonic=all(b['darkPixels']>=a['darkPixels'] for a,b in zip(counts,counts[1:]))
# A pink accent intentionally replaces dark pixels, so dark-area monotonicity
# is meaningful only for the plain black opening, not the colored comparison.
if len(report['meshes'])==1:assert monotonic
report['darkAreaMonotonic']=monotonic
report['darkAreaGateApplied']=len(report['meshes'])==1
report['frontDarkArea']=counts
(folder/'measurements.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'run':args.run,'mouthMeshes':len(report['meshes']),'zeroRestorationCases':len(view['mouthZeroRestoration']),'neutralMaxDifference':max(c['maxChannelDifference'] for c in view['mouthZeroRestoration'])}))
