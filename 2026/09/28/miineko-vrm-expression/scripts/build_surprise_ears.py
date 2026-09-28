"""Raise only the ear tips with a localized, reproducible shape key."""
import copy,hashlib,json,os,struct
from pathlib import Path
import numpy as np
root=Path(__file__).resolve().parents[1];source=root/'artifacts/eye-emotions-steeper'
suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ('','-repeat')
out=root/'artifacts'/('surprise-ears'+suffix);out.mkdir(exist_ok=True)
raw=(source/'continuous-blink.vrm').read_bytes();size=struct.unpack_from('<I',raw,12)[0];original=json.loads(raw[20:20+size]);doc=copy.deepcopy(original);binary=bytearray(raw[28+size:]);source_binary=bytes(binary)
assert hashlib.sha256(raw).hexdigest()==json.loads((source/'report.json').read_text())['outputSha256']
def smooth(t):
 t=np.clip(t,0,1);return t*t*(3-2*t)
def deform(p):
 x,y,z=p.T;side=np.where(x>=0,1.,-1.);base=1.004-.38*abs(x)
 w=smooth((y-base)/.045)*smooth((abs(x)-.16)/.04)*(1-smooth((abs(z)-.10)/.05))
 angle=side*np.deg2rad(25)*w;c=np.cos(angle);s=np.sin(angle);dx=x-side*.20;dy=y-.915
 q=p.copy();q[:,0]=side*.20+c*dx-s*dy;q[:,1]=.915+s*dx+c*dy
 return q,w

def read(index):
 a=doc['accessors'][index];v=doc['bufferViews'][a['bufferView']];assert a['componentType']==5126 and 'byteStride' not in v
 return np.frombuffer(source_binary,dtype='<f4',count=a['count']*3,offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(-1,3).astype(float)
def accessor(a):
 a=a.astype('<f4');binary.extend(b'\0'*((-len(binary))%4));offset=len(binary);binary.extend(a.tobytes());doc['bufferViews'].append({'buffer':0,'byteOffset':offset,'byteLength':a.nbytes});doc['accessors'].append({'bufferView':len(doc['bufferViews'])-1,'componentType':5126,'count':len(a),'type':'VEC3','min':a.min(0).tolist(),'max':a.max(0).tolist()});return len(doc['accessors'])-1
mesh_index=next(i for i,m in enumerate(doc['meshes']) if m['name'].startswith('tripo_mesh'))
mesh=doc['meshes'][mesh_index];assert all(not p.get('targets') for p in mesh['primitives']);details=[]
for p in mesh['primitives']:
 xyz=read(p['attributes']['POSITION']);normal=read(p['attributes']['NORMAL']);q,w=deform(xyz);delta=q-xyz;delta[w==0]=0
 # The inverse transpose preserves normals through the softly varying rotation.
 jac=np.zeros((len(xyz),3,3));eps=1e-5
 for i in range(3):
  d=np.zeros_like(xyz);d[:,i]=eps;jac[:,:,i]=(deform(xyz+d)[0]-deform(xyz-d)[0])/(2*eps)
 det=np.linalg.det(jac);assert det.min()>.1, float(det.min())
 nn=np.linalg.solve(jac.transpose(0,2,1),normal[:,:,None])[:,:,0];nn/=np.linalg.norm(nn,axis=1)[:,None];dn=nn-normal;dn[w==0]=0
 p['targets']=[{'POSITION':accessor(delta),'NORMAL':accessor(dn)}]
 protected=(xyz[:,1]<.84)|(abs(xyz[:,0])<.16)|(abs(xyz[:,2])>.15)
 assert not np.any(delta[protected])
 moved=np.linalg.norm(delta,axis=1)>1e-9
 details.append({'vertices':len(xyz),'moved':int(moved.sum()),'maxDisplacement':float(np.linalg.norm(delta,axis=1).max()),'minimumJacobianDeterminant':float(det.min()),'protectedUnchanged':True})
mesh['weights']=[0];mesh.setdefault('extras',{})['targetNames']=['Surprise Ears Up']
nodes=[i for i,n in enumerate(doc['nodes']) if n.get('mesh')==mesh_index]
preset=doc['extensions']['VRMC_vrm']['expressions']['preset'];preset['surprised']={**preset['surprised'],'morphTargetBinds':[{'node':i,'index':0,'weight':1} for i in nodes]}
assert all(preset[k]==v for k,v in original['extensions']['VRMC_vrm']['expressions']['preset'].items() if k!='surprised');assert bytes(binary[:len(source_binary)])==source_binary
doc['buffers'][0]['byteLength']=len(binary);binary.extend(b'\0'*((-len(binary))%4));encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
target=struct.pack('<4sII',b'glTF',2,28+len(encoded)+len(binary))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+struct.pack('<I4s',len(binary),b'BIN\0')+binary;(out/'continuous-blink.vrm').write_bytes(target)
# Save the same endpoint in the authoring scene, without re-exporting its materials.
import bpy
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'));body=bpy.data.objects['Miineko_Body'];assert body.data.shape_keys is None
body.shape_key_add(name='Basis');key=body.shape_key_add(name='Surprise Ears Up')
p=np.array([v.co for v in body.data.vertices]);g=p[:,[0,2,1]].copy();g[:,2]*=-1;q,w=deform(g);q[w==0]=g[w==0];q[:,2]*=-1;b=q[:,[0,2,1]]
for v,co in zip(key.data,b):v.co=co
expr=bpy.data.objects['Miineko_Rig'].data.vrm_addon_extension.vrm1.expressions.preset.surprised
expr.morph_target_binds.clear();expr.texture_transform_binds.clear();expr.material_color_binds.clear();bind=expr.morph_target_binds.add();bind.node.mesh_object_name=body.name;bind.index=key.name;bind.weight=1
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
report={'sourceSha256':hashlib.sha256(raw).hexdigest(),'outputSha256':hashlib.sha256(target).hexdigest(),'angleDegrees':25,'pivot':[.20,.915,0],'earBaseLine':'y=1.004-.38*abs(x)','featherHeight':.045,'primitives':details,'originalBinaryPrefixUnchanged':True,'scope':'ear-only localized rotation morph; original eye, face, mouth and textures retained; mouth driven independently'}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
