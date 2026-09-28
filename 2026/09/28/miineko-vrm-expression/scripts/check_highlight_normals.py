"""Check that this runtime change only replaces a local normal accessor."""
import bpy,copy,json,struct,hashlib
from pathlib import Path
import numpy as np
root=Path(__file__).resolve().parents[1];source=root/'artifacts/blink-aligned';folder=root/'artifacts/highlight-clean-r'
def load(p):
 raw=p.read_bytes();n=struct.unpack_from('<I',raw,12)[0];return json.loads(raw[20:20+n]),raw[28+n:]
def read(d,b,i):
 a=d['accessors'][i];v=d['bufferViews'][a['bufferView']];return np.frombuffer(b,dtype='<f4',count=a['count']*3,offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(-1,3)
base,bb=load(source/'continuous-blink.vrm');new,nb=load(folder/'continuous-blink.vrm');assert nb[:len(bb)]==bb
bi=next(i for i,m in enumerate(base['meshes']) if m['name'].startswith('tripo_mesh'));pi=next(i for i,p in enumerate(base['meshes'][bi]['primitives']) if base['materials'][p['material']]['name']=='Original eye material R');bp=base['meshes'][bi]['primitives'][pi];np_=new['meshes'][bi]['primitives'][pi];a=read(base,bb,bp['attributes']['NORMAL']);b=read(new,nb,np_['attributes']['NORMAL']);mask=np.any(a!=b,axis=1);assert mask.sum()==58
restored=copy.deepcopy(new);restored['meshes'][bi]['primitives'][pi]['attributes']['NORMAL']=bp['attributes']['NORMAL'];restored['accessors']=restored['accessors'][:len(base['accessors'])];restored['bufferViews']=restored['bufferViews'][:len(base['bufferViews'])];restored['buffers']=base['buffers'];assert restored==base
assert (folder/'continuous-blink.vrm').read_bytes()==(root/'artifacts/highlight-clean-r-repeat/continuous-blink.vrm').read_bytes()
bpy.ops.wm.open_mainfile(filepath=str(folder/'continuous-blink.blend'));mesh=bpy.data.objects['Miineko_Body'].data;points=read(new,nb,np_['attributes']['POSITION'])[mask];normals=b[mask];errors=[]
for poly in mesh.polygons:
 if mesh.materials[poly.material_index].name!='Original eye material R':continue
 for li in poly.loop_indices:
  p=mesh.vertices[mesh.loops[li].vertex_index].co;dist=np.linalg.norm(points-[p.x,p.z,-p.y],axis=1);i=int(dist.argmin())
  if dist[i]<2e-6:
   v=mesh.corner_normals[li].vector;errors.append(float(np.linalg.norm(normals[i]-[v.x,v.z,-v.y])))
assert errors and max(errors)<.001
report={'changedNormalVertices':int(mask.sum()),'allOtherJsonAndSourceBinaryRetained':True,'imagesUVPositionsExpressionsRetained':True,'repeatByteIdentical':True,'savedBlendMatchingCorners':len(errors),'maxSavedNormalError':max(errors),'outputSha256':hashlib.sha256((folder/'continuous-blink.vrm').read_bytes()).hexdigest()};(root/'results/highlight-normal-structure.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
