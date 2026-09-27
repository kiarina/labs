"""Write standard glTF NORMAL morph deltas for the stitched surface probe.

Blender custom normals can be tied to the source face frames. This experiment
instead defines explicit open/closed normal fields and interpolates them, as
glTF does. No viewer-specific shader or VRM extension is introduced.
"""
import itertools
import json
import os
from pathlib import Path
import struct

import numpy as np

root=Path(__file__).resolve().parents[1]
folder=root/'artifacts'/os.environ.get('BLINK_RUN','stitched-blink-morph-normals')
path=folder/'continuous-blink.vrm'
backup=folder/'before-normal-patch.vrm'
raw=(backup if backup.exists() else path).read_bytes();size=struct.unpack_from('<I',raw,12)[0]
doc=json.loads(raw[20:20+size]);blob=bytearray(raw[28+size:])
fields=np.load(folder/'morph-normals.npz')

def yup(values):
    return np.stack((values[:,0],values[:,2],-values[:,1]),axis=-1)

positions=yup(fields['positions']);base=yup(fields['base']);target=yup(fields['target'])
buckets={}
for index,key in enumerate(np.floor(positions*1e5).astype(int)):
    buckets.setdefault(tuple(key),[]).append(index)
neighbors=list(itertools.product((-1,0,1),repeat=3))

def lookup(position):
    key=np.floor(position*1e5).astype(int)
    candidates=[]
    for delta in neighbors:candidates.extend(buckets.get(tuple(key+delta),[]))
    if not candidates:return None
    distances=np.linalg.norm(positions[candidates]-position,axis=1)
    i=int(np.argmin(distances))
    return candidates[i] if distances[i]<3e-6 else None

def read_accessor(index):
    a=doc['accessors'][index];v=doc['bufferViews'][a['bufferView']]
    assert a['componentType']==5126 and a['type']=='VEC3'
    return np.ndarray((a['count'],3),dtype='<f4',buffer=blob,
                      offset=v.get('byteOffset',0)+a.get('byteOffset',0),
                      strides=(v.get('byteStride',12),4)).copy()

def add_accessor(values):
    blob.extend(b'\0'*((-len(blob))%4));start=len(blob)
    blob.extend(np.asarray(values,dtype='<f4').tobytes())
    view=len(doc['bufferViews']);doc['bufferViews'].append({'buffer':0,'byteOffset':start,'byteLength':len(values)*12,'target':34962})
    index=len(doc['accessors']);doc['accessors'].append({'bufferView':view,'componentType':5126,'count':len(values),'type':'VEC3'})
    return index

matched=set();count=0
for mesh in doc['meshes']:
    names=mesh.get('extras',{}).get('targetNames',[])
    if not all(n in names for n in ('CloseL','CloseR')):continue
    for primitive in mesh['primitives']:
        pos=read_accessor(primitive['attributes']['POSITION'])
        normal=read_accessor(primitive['attributes']['NORMAL'])
        morph=[read_accessor(t['NORMAL']) if 'NORMAL' in t else np.zeros_like(normal) for t in primitive['targets']]
        changed=False
        for vertex,position in enumerate(pos):
            index=lookup(position)
            if index is None:continue
            matched.add(index);count+=1;changed=True
            normal[vertex]=base[index]
            for ti,name in enumerate(names):
                own=name==('CloseL' if fields['side'][index]==0 else 'CloseR')
                morph[ti][vertex]=target[index]-base[index] if own else 0
        if changed:
            primitive['attributes']['NORMAL']=add_accessor(normal)
            for t,values in zip(primitive['targets'],morph):t['NORMAL']=add_accessor(values)
assert len(matched)==len(positions),(len(matched),len(positions))
doc['buffers'][0]['byteLength']=len(blob)
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
blob.extend(b'\0'*((-len(blob))%4))
result=struct.pack('<III',0x46546c67,2,28+len(encoded)+len(blob))+struct.pack('<II',len(encoded),0x4e4f534a)+encoded+struct.pack('<II',len(blob),0x004e4942)+blob
if not backup.exists():backup.write_bytes(raw)
path.write_bytes(result)
report={'sourceVertices':len(positions),'matchedVertices':len(matched),'exportedVerticesChanged':count,'normalTargets':['CloseL','CloseR'],'bytes':len(result)}
(folder/'normal-export-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
