"""Inspect red-ribbon skin weights using source texture color, not rendered poses."""
from pathlib import Path
import struct,json,io
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];raw=(root/'artifacts/blink-aligned/continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0];d=json.loads(raw[20:20+n]);data=raw[28+n:]
def arr(i):
 a=d['accessors'][i];v=d['bufferViews'][a['bufferView']];return np.frombuffer(data,dtype={5126:'<f4',5123:'<u2',5121:'u1',5125:'<u4'}[a['componentType']],count=a['count']*{'VEC2':2,'VEC3':3,'VEC4':4,'SCALAR':1}[a['type']],offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(a['count'],-1)
mi=next(i for i,m in enumerate(d['meshes']) if m['name'].startswith('tripo_mesh'));node=next(v for v in d['nodes'] if v.get('mesh')==mi);skin=d['skins'][node['skin']];p=d['meshes'][mi]['primitives'][0];a=p['attributes'];xyz=arr(a['POSITION']);uv=arr(a['TEXCOORD_0']);weights=arr(a['WEIGHTS_0']);joints=arr(a['JOINTS_0']);mat=d['materials'][p['material']];tex=d['textures'][mat['pbrMetallicRoughness']['baseColorTexture']['index']];im=d['images'][tex['source']];v=d['bufferViews'][im['bufferView']];rgb=np.array(Image.open(io.BytesIO(data[v.get('byteOffset',0):v.get('byteOffset',0)+v['byteLength']])).convert('RGB'));h,w=rgb.shape[:2];c=rgb[np.clip((uv[:,1]*h).astype(int),0,h-1),np.clip((uv[:,0]*w).astype(int),0,w-1)].astype(float)
# glTF UV origin is the upper-left image origin.
mask=(c[:,0]>100)&(c[:,0]>2*c[:,1])&(c[:,0]>1.8*c[:,2])&(xyz[:,1]>.20)&(xyz[:,1]<.40)&(abs(xyz[:,0])<.18)&(xyz[:,2]>.10)
assert mask.sum()>20
rows=[]
for j in np.unique(joints[mask]):
 influence=np.where(joints[mask]==j,weights[mask],0).sum(1);rows.append({'bone':d['nodes'][skin['joints'][int(j)]]['name'],'verticesAboveOnePercent':int((influence>.01).sum()),'maxWeight':float(influence.max()),'meanWeight':float(influence.mean())})
rows.sort(key=lambda x:-x['meanWeight']);report={'scope':'red texture samples in ribbon-height region, duplicated seam vertices included; not exhaustive semantic segmentation','selectedVertices':int(mask.sum()),'bounds':[xyz[mask].min(0).tolist(),xyz[mask].max(0).tolist()],'influences':rows};(root/'results/body-ribbon-weights.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
