"""Refit the fixed lids to the foremost face surface, removing copied folded facets."""
import bpy,json,struct,copy,hashlib,os
import numpy as np
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree
root=Path(__file__).resolve().parents[1];source=root/'artifacts/lid-rim-clean';suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ('','-repeat')
out=root/'artifacts'/('lid-envelope'+suffix);out.mkdir(exist_ok=True)
raw=(source/'continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0];base=json.loads(raw[20:20+n]);doc=copy.deepcopy(base);bb=raw[28+n:];binary=bytearray(bb)
assert hashlib.sha256(raw).hexdigest()==json.loads((source/'report.json').read_text())['outputSha256']
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'));body=bpy.data.objects['Miineko_Body'];mesh=body.data;mesh.calc_loop_triangles();positions=[v.co.copy() for v in mesh.vertices];tris=[tuple(t.vertices) for t in mesh.loop_triangles];bvh=BVHTree.FromPolygons(positions,tris,all_triangles=True)
cache={}
def depth(x,z):
 key=(round(float(x),7),round(float(z),7))
 if key not in cache:
  hits=[]
  for dx,dz in [(dx,dz) for dx in [-.002,0,.002] for dz in [-.002,0,.002]]:
   hit,_,_,_=bvh.ray_cast(Vector((float(x)+dx,-1,float(z)+dz)),Vector((0,1,0)))
   if hit is not None:hits.append(-hit.y)
  assert hits
  cache[key]=max(hits)
 return cache[key]
def read(i):
 a=doc['accessors'][i];v=doc['bufferViews'][a['bufferView']];return np.frombuffer(bb,dtype='<f4',count=a['count']*3,offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(-1,3).copy()
changes=[]
for m in doc['meshes']:
 if not m['name'].startswith('Surface Lid'):continue
 offset=.0009 if m['name'].endswith('ink') else .0007 if m['name'].endswith('upper') else .0004
 for p in m['primitives']:
  xyz=read(p['attributes']['POSITION']);new=xyz.copy();new[:,2]=[depth(x,y)+offset for x,y,_ in xyz]
  binary.extend(b'\0'*((-len(binary))%4));start=len(binary);payload=new.astype('<f4').tobytes();binary.extend(payload);doc['bufferViews'].append({'buffer':0,'byteOffset':start,'byteLength':len(payload)});doc['accessors'].append({'bufferView':len(doc['bufferViews'])-1,'componentType':5126,'count':len(new),'type':'VEC3','min':new.min(0).tolist(),'max':new.max(0).tolist()});p['attributes']['POSITION']=len(doc['accessors'])-1
  changes.append({'mesh':m['name'],'maxDepthChange':float(abs(new[:,2]-xyz[:,2]).max()),'vertices':len(new)})
 obj=bpy.data.objects[m['name']];normals=[n.vector.copy() for n in obj.data.corner_normals];tree=KDTree(len(xyz))
 for i,point in enumerate(xyz):tree.insert(Vector((float(point[0]),float(point[1]),0)),i)
 tree.balance()
 for v in obj.data.vertices:
  _,i,distance=tree.find(Vector((v.co.x,v.co.z,0)));assert distance<2e-6;v.co.y=-float(new[i,2])
 obj.data.update();obj.data.normals_split_custom_set(normals)
doc['buffers'][0]['byteLength']=len(binary);binary.extend(b'\0'*((-len(binary))%4));encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4);target=struct.pack('<4sII',b'glTF',2,28+len(encoded)+len(binary))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+struct.pack('<I4s',len(binary),b'BIN\0')+binary;(out/'continuous-blink.vrm').write_bytes(target);bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
report={'sourceSha256':hashlib.sha256(raw).hexdigest(),'outputSha256':hashlib.sha256(target).hexdigest(),'changes':changes,'samplingRadius':.002,'samplingPattern':'3x3 foremost-surface maximum','scope':'only depth of existing six lid/ink meshes; original head/eye geometry and all UV/color/alpha/binds retained'};(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
