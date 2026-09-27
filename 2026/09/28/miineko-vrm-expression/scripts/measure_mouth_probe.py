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
report={'run':args.run,'vrmSha256':hashlib.sha256(raw).hexdigest(),'meshes':[],'bodyOutlineMorph':[]}
colored_fill=False
for binding in aa['morphTargetBinds']:
    node=doc['nodes'][binding['node']];mesh=doc['meshes'][node['mesh']]
    target_name=mesh['extras']['targetNames'][binding['index']]
    if node['name']=='Miineko_Body' and target_name=='MouthOutlineLight':
        for primitive in mesh['primitives']:
            pos=accessor(primitive['attributes']['POSITION'])
            delta=accessor(primitive['targets'][binding['index']]['POSITION'])
            moved=np.linalg.norm(delta,axis=1)>1e-7
            if not moved.any():continue
            coords=pos[moved]
            # glTF is Y-up, corresponding to the source model's Z.
            assert coords[:,1].min()>.425-1e-6 and coords[:,1].max()<.491+1e-6
            assert abs(coords[:,0]).max()<.095+1e-6
            assert not np.any((abs(coords[:,0])<.018-1e-6)&(coords[:,1]>.481+1e-6))
            report['bodyOutlineMorph'].append({'changedExportVertices':int(moved.sum()),'minimum':coords.min(0).tolist(),'maximum':coords.max(0).tolist(),'maximumDisplacement':float(np.linalg.norm(delta[moved],axis=1).max()),'noseAndEyePositionPinsPassed':True})
        continue
    assert node['name'].startswith('Mouth') and target_name=='AA'
    skin=doc['skins'][node['skin']]
    for p in mesh['primitives']:
        material=doc['materials'][p['material']]
        if max(material.get('emissiveFactor',[0,0,0]))>.05:colored_fill=True
        if 'COLOR_0' in p['attributes'] and accessor(p['attributes']['COLOR_0'])[:,:3].max()>.05:colored_fill=True
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
report['viewer']={'errors':view['errors'],'warnings':view['warnings'],'mouthStates':len(view['mouthStates']),'zeroRestoration':view['mouthZeroRestoration'],'relaxedCompositionMaximumDifference':max(x['maxChannelDifference'] for x in view['relaxedComposition']),'headFollowing':view.get('headFollowing',[]),'eyePreservation':view.get('mouthEyePreservation',[]),'vowelStates':len(view.get('vowels',[])),'vowelMixes':view.get('vowelMixes',[])}
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
if not colored_fill:assert monotonic
report['darkAreaMonotonic']=monotonic
report['darkAreaGateApplied']=not colored_fill
report['frontDarkArea']=counts
if view.get('vowels'):
    report['vowelNeutralDifferences']=[]
    for angle in (0,45,-45):
        expected=np.asarray(Image.open(folder/'viewer'/f'vowel-aa-0-{angle}.png').convert('RGB')).astype(float)
        for vowel in ('ih','ou','ee','oh'):
            actual=np.asarray(Image.open(folder/'viewer'/f'vowel-{vowel}-0-{angle}.png').convert('RGB')).astype(float)
            diff=float(abs(expected-actual).max())
            assert diff<=2
            report['vowelNeutralDifferences'].append({'vowel':vowel,'angle':angle,'maximum':diff})
    report['vowelShapeDifferences']=[]
    vowel_names=('aa','ih','ou','ee','oh')
    images={name:np.asarray(Image.open(folder/'viewer'/f'vowel-{name}-1-0.png').convert('RGB')).astype(float) for name in vowel_names}
    for i,a in enumerate(vowel_names):
        for b in vowel_names[i+1:]:
            changed=int((abs(images[a]-images[b]).max(-1)>12).sum())
            assert changed>10
            report['vowelShapeDifferences'].append({'a':a,'b':b,'changedPixelsAbove12':changed})
(folder/'measurements.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'run':args.run,'mouthMeshes':len(report['meshes']),'zeroRestorationCases':len(view['mouthZeroRestoration']),'neutralMaxDifference':max(c['maxChannelDifference'] for c in view['mouthZeroRestoration'])}))
