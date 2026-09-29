"""Audit RGB-only changes on four fixed lids and preserve the source model."""
import bpy,copy,json,struct,hashlib
import numpy as np
from pathlib import Path
root=Path(__file__).resolve().parents[1];source=root/'artifacts/highlight-clean-r';folder=root/'artifacts/lid-rim-clean'
def load(p):
 raw=p.read_bytes();n=struct.unpack_from('<I',raw,12)[0];return json.loads(raw[20:20+n]),raw[28+n:]
def colors(d,b,i):
 a=d['accessors'][i];v=d['bufferViews'][a['bufferView']];assert a['componentType']==5123 and a['normalized'];return np.frombuffer(b,dtype='<u2',count=a['count']*4,offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(-1,4)
base,bb=load(source/'continuous-blink.vrm');new,nb=load(folder/'continuous-blink.vrm');assert nb[:len(bb)]==bb;restored=copy.deepcopy(new);changes=[]
for i,m in enumerate(base['meshes']):
 for j,p in enumerate(m['primitives']):
  q=new['meshes'][i]['primitives'][j]
  if p['attributes']==q['attributes']:continue
  assert m['name'].startswith('Surface Lid') and not m['name'].endswith('ink')
  a=colors(base,bb,p['attributes']['COLOR_0']);b=colors(new,nb,q['attributes']['COLOR_0']);assert np.array_equal(a[:,3],b[:,3]);assert np.any(a[:,:3]!=b[:,:3]);restored['meshes'][i]['primitives'][j]['attributes']['COLOR_0']=p['attributes']['COLOR_0'];changes.append(m['name'])
assert len(changes)==4
restored['accessors']=restored['accessors'][:len(base['accessors'])];restored['bufferViews']=restored['bufferViews'][:len(base['bufferViews'])];restored['buffers']=base['buffers'];assert restored==base
assert (folder/'continuous-blink.vrm').read_bytes()==(root/'artifacts/lid-rim-clean-repeat/continuous-blink.vrm').read_bytes()
def scene_data(path):
 bpy.ops.wm.open_mainfile(filepath=str(path));out={}
 for obj in bpy.data.objects:
  if obj.type!='MESH':continue
  mesh=obj.data;out[obj.name]={'vertices':np.array([v.co for v in mesh.vertices]),'normals':np.array([n.vector for n in mesh.corner_normals]),'uv':np.array([l.uv for l in mesh.uv_layers[0].data]),'colors':np.array([c.color for c in mesh.color_attributes['SkinTint'].data]) if 'SkinTint' in mesh.color_attributes else None}
 return out
old=scene_data(source/'continuous-blink.blend');current=scene_data(folder/'continuous-blink.blend')
for name,values in old.items():
 for field in ['vertices','normals','uv']:assert np.array_equal(values[field],current[name][field]),(name,field)
 if values['colors'] is not None:
  if name in changes:assert np.array_equal(values['colors'][:,3],current[name]['colors'][:,3])
  else:assert np.array_equal(values['colors'],current[name]['colors'])
report={'onlyFourLidRGBAccessorsChanged':True,'alphaUnchanged':True,'geometryUVNormalsMaterialsImagesExpressionsUnchanged':True,'sourceBinaryPrefixUnchanged':True,'savedBlendGeometryAndAlphaUnchanged':True,'repeatByteIdentical':True,'changedLids':changes,'outputSha256':hashlib.sha256((folder/'continuous-blink.vrm').read_bytes()).hexdigest()};(root/'results/lid-rim-structure.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
