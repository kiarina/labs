"""Check unchanged frontal geometry and measure changes in actual front renders."""
import argparse
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image

parser=argparse.ArgumentParser();parser.add_argument('candidate')
parser.add_argument('--baseline',default='mouth-vowels-flatstart')
parser.add_argument('--full-targets',action='store_true')
parser.add_argument('--preserve-vowels',default='');args=parser.parse_args()
root=Path(__file__).resolve().parents[1]/'artifacts'
baseline=root/args.baseline;candidate=root/args.candidate

def read_mesh(folder):
    raw=(folder/'continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0]
    doc=json.loads(raw[20:20+n]);blob=raw[28+n:]
    def accessor(index):
        a=doc['accessors'][index];v=doc['bufferViews'][a['bufferView']]
        width={'VEC2':2,'VEC3':3}[a['type']]
        assert a['componentType']==5126
        return np.ndarray((a['count'],width),dtype='<f4',buffer=blob,
            offset=v.get('byteOffset',0)+a.get('byteOffset',0),
            strides=(v.get('byteStride',width*4),4)).copy()
    node=next(n for n in doc['nodes'] if n.get('name')=='Mouth_Cartoon')
    mesh=doc['meshes'][node['mesh']];assert len(mesh['primitives'])==1
    p=mesh['primitives'][0]
    return [accessor(p['attributes']['POSITION']),*[accessor(t['POSITION']) for t in p['targets']]],accessor(p['attributes']['TEXCOORD_0']),mesh['extras']['targetNames']

a,auv,anames=read_mesh(baseline);b,buv,bnames=read_mesh(candidate)
assert anames==bnames
assert len(a)==len(b)
assert np.array_equal(auv,buv)
geometry=[]
for x,y in zip(a,b):
    # glTF Y is height and Z is depth. Only depth may change in this trial.
    assert np.array_equal(x[:,:2],y[:,:2])
    geometry.append({'maximumDepthChange':float(abs(x[:,2]-y[:,2]).max())})
for target in [b[0],*[b[0]+d for d in b[1:]]]:
    for x in np.unique(target[:,0]):
        column=target[target[:,0]==x]
        if np.ptp(column[:,1])<1e-7:
            assert np.ptp(column[:,2])<1e-7, 'Collapsed column became a depth shelf'
images=[]
for vowel in ('aa','ih','ou','ee','oh'):
    for weight in (0,.1,.22,.5,1):
        name=f'vowel-{vowel}-{weight}-0.png'
        old=np.asarray(Image.open(baseline/'viewer'/name).convert('RGB')).astype(float)
        new=np.asarray(Image.open(candidate/'viewer'/name).convert('RGB')).astype(float)
        assert old.shape==new.shape
        difference=abs(old-new)
        images.append({'vowel':vowel,'weight':weight,'meanChannelDifference':float(difference.mean()),
            'maximumChannelDifference':float(difference.max()),'changedPixelsAbove2':int((difference.max(2)>2).sum())})
report={'baseline':baseline.name,'candidate':candidate.name,'frontalCoordinatesAndUvsExact':True,
    'depthChanges':geometry,'frontRenders':images,
    'scope':'same frontal outline coordinates; occlusion can still alter rendered appearance'}
if args.full_targets:
    report['fullTargetMaximumCoordinateDifference']=max(float(abs((a[0]+x)-(b[0]+y)).max()) for x,y in zip(a[1:],b[1:]))
    assert report['fullTargetMaximumCoordinateDifference']<1e-7
    report['fullOpenViews']=[]
    for vowel in ('aa','ih','ou','ee','oh'):
        for angle in (0,45,-45,90,-90):
            name=f'vowel-{vowel}-1-{angle}.png'
            old=np.asarray(Image.open(baseline/'viewer'/name).convert('RGB')).astype(float)
            new=np.asarray(Image.open(candidate/'viewer'/name).convert('RGB')).astype(float)
            diff=abs(old-new);changed=int((diff.max(2)>2).sum())
            # Rebased float32 deltas can change a few edge pixels even when
            # full-target coordinates agree within 1e-7 m. Bound the affected
            # area and average error, and retain the maximum rather than hiding it.
            assert changed<=old.shape[0]*old.shape[1]*.0001 and diff.mean()<.001
            report['fullOpenViews'].append({'vowel':vowel,'angle':angle,'maximumChannelDifference':float(diff.max()),'changedPixelsAbove2':changed,'meanChannelDifference':float(diff.mean())})
if args.preserve_vowels:
    assert np.array_equal(a[0],b[0]),'Neutral mesh changed'
    report['preservedVowelViews']=[]
    for vowel in args.preserve_vowels.split(','):
        index=anames.index(vowel.upper())+1
        assert np.array_equal(a[index],b[index]),f'{vowel} morph changed'
        for weight in (0,.02,.05,.1,.18,.22,.25,.5,.75,1):
            for angle in (0,45,-45,90,-90):
                name=f'{vowel}-{weight}-{angle}.png'
                old=np.asarray(Image.open(baseline/'viewer'/name).convert('RGB')).astype(float)
                new=np.asarray(Image.open(candidate/'viewer'/name).convert('RGB')).astype(float)
                maximum=float(abs(old-new).max());assert maximum<=2
                report['preservedVowelViews'].append({'vowel':vowel,'weight':weight,'angle':angle,'maximumChannelDifference':maximum})
output='preserved-vowel-comparison.json' if args.preserve_vowels else ('onset-comparison.json' if args.full_targets else 'profile-comparison.json')
(candidate/output).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'frontImages':len(images),'maximumChangedPixels':max(i['changedPixelsAbove2'] for i in images)}))
