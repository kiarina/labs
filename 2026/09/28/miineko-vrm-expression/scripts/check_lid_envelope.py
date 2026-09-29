import bpy,copy,json,struct,hashlib
import numpy as np
from pathlib import Path
from mathutils import Vector
from mathutils.kdtree import KDTree
root=Path(__file__).resolve().parents[1];source=root/'artifacts/lid-rim-clean';folder=root/'artifacts/lid-envelope'
def load(p):
 raw=p.read_bytes();n=struct.unpack_from('<I',raw,12)[0];return json.loads(raw[20:20+n]),raw[28+n:]
def read(d,b,i):
 a=d['accessors'][i];v=d['bufferViews'][a['bufferView']];return np.frombuffer(b,dtype='<f4',count=a['count']*3,offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(-1,3)
base,bb=load(source/'continuous-blink.vrm');new,nb=load(folder/'continuous-blink.vrm');assert nb[:len(bb)]==bb;restore=copy.deepcopy(new);changes=[]
for i,m in enumerate(base['meshes']):
 for j,p in enumerate(m['primitives']):
  q=new['meshes'][i]['primitives'][j]
  if p['attributes']==q['attributes']:continue
  assert m['name'].startswith('Surface Lid');a=read(base,bb,p['attributes']['POSITION']);b=read(new,nb,q['attributes']['POSITION']);assert np.array_equal(a[:,:2],b[:,:2]);changes.append(m['name']);restore['meshes'][i]['primitives'][j]['attributes']['POSITION']=p['attributes']['POSITION']
assert len(changes)==6
restore['accessors']=restore['accessors'][:len(base['accessors'])];restore['bufferViews']=restore['bufferViews'][:len(base['bufferViews'])];restore['buffers']=base['buffers'];assert restore==base
assert (folder/'continuous-blink.vrm').read_bytes()==(root/'artifacts/lid-envelope-repeat/continuous-blink.vrm').read_bytes()
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'));body=np.array([v.co for v in bpy.data.objects['Miineko_Body'].data.vertices]);bpy.ops.wm.open_mainfile(filepath=str(folder/'continuous-blink.blend'));assert np.array_equal(body,np.array([v.co for v in bpy.data.objects['Miineko_Body'].data.vertices]));max_error=0
for m in new['meshes']:
 if m['name'] not in changes:continue
 xyz=read(new,nb,m['primitives'][0]['attributes']['POSITION']);tree=KDTree(len(xyz))
 for i,p in enumerate(xyz):tree.insert(Vector(tuple(float(v) for v in p)),i)
 tree.balance()
 for v in bpy.data.objects[m['name']].data.vertices:
  _,_,distance=tree.find(Vector((v.co.x,v.co.z,-v.co.y)));max_error=max(max_error,distance)
assert max_error<2e-6
report={'onlySixLidDepthAccessorsChanged':True,'headBodyAndEyeSourceUnchanged':True,'frontXYUVNormalsColorsAlphaImagesBindsRetained':True,'repeatByteIdentical':True,'savedBlendMaxPositionError':max_error,'outputSha256':hashlib.sha256((folder/'continuous-blink.vrm').read_bytes()).hexdigest()};(root/'results/lid-envelope-structure.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
