"""Remove copied eye-rim discoloration from fixed lid vertex colors only."""
import bpy,copy,json,hashlib,os,struct
from pathlib import Path
import numpy as np
root=Path(__file__).resolve().parents[1];source=root/'artifacts/highlight-clean-r';suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ('','-repeat')
out=root/'artifacts'/('lid-rim-clean'+suffix);out.mkdir(exist_ok=True)
raw=(source/'continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0];base=json.loads(raw[20:20+n]);doc=copy.deepcopy(base);binary=bytearray(raw[28+n:]);bb=bytes(binary)
assert hashlib.sha256(raw).hexdigest()==json.loads((source/'report.json').read_text())['outputSha256']
def read(i):
 a=doc['accessors'][i];v=doc['bufferViews'][a['bufferView']];sizes={'VEC3':3,'VEC4':4};dtype={5126:'<f4',5123:'<u2'}[a['componentType']];q=np.frombuffer(bb,dtype=dtype,count=a['count']*sizes[a['type']],offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(a['count'],-1).astype(float)
 if a.get('normalized'):q/=65535
 return q

def smooth(x):x=np.clip(x,0,1);return x*x*(3-2*x)
def clean(xyz,colors,center,coefs):
 u=(xyz[:,0]-center)/.104;v=(xyz[:,1]-.619)/.113;r=np.hypot(u,v);design=np.stack([np.ones_like(u),u,v,u*u,u*v,v*v],axis=1);rgb=np.clip(design@coefs,0,1)
 weight=1-smooth((r-1.03)/.19);result=colors.copy();result[:,:3]=colors[:,:3]*(1-weight[:,None])+rgb*weight[:,None];return result
fits={};reports=[]
# Fit each eye once, from clean outer skin, with equal influence per spatial bin.
for side,cx in [('L',.1764),('R',-.1848)]:
 m=next(m for m in doc['meshes'] if m['name']==f'Surface Lid {side} upper');a=m['primitives'][0]['attributes'];xyz=read(a['POSITION']);c=read(a['COLOR_0']);u=(xyz[:,0]-cx)/.104;v=(xyz[:,1]-.619)/.113;r=np.hypot(u,v);mask=(r>1.08)&(r<1.30)&(c[:,0]>.25)&(c[:,1]<.1)&(c[:,2]>.05)
 cells={}
 for i in np.flatnonzero(mask):cells.setdefault(tuple(np.rint(np.array([u[i],v[i]])*30).astype(int)),[]).append(i)
 points=[];rgb=[]
 for ids in cells.values():points.append([u[ids].mean(),v[ids].mean()]);rgb.append(np.median(c[ids,:3],axis=0))
 points=np.array(points);rgb=np.array(rgb);assert len(points)>60;u,v=points.T;design=np.stack([np.ones_like(u),u,v,u*u,u*v,v*v],axis=1)
 keep=np.ones(len(rgb),bool)
 for _ in range(3):
  coefs=np.linalg.lstsq(design[keep],rgb[keep],rcond=None)[0];err=np.linalg.norm(rgb-design@coefs,axis=1);keep=err<=max(.025,np.quantile(err,.85))
 fits[side]=(cx,coefs);reports.append({'side':side,'skinSampleBins':len(points),'fitBins':int(keep.sum()),'coefficients':coefs.tolist()})
changed=[]
for m in doc['meshes']:
 if not m['name'].startswith('Surface Lid') or m['name'].endswith('ink'):continue
 side=m['name'].split()[2];cx,coefs=fits[side]
 for p in m['primitives']:
  attrs=p['attributes'];xyz=read(attrs['POSITION']);colors=read(attrs['COLOR_0']);new=clean(xyz,colors,cx,coefs)
  # Keep alpha bit-exact, and store RGB in the original normalized U16 format.
  quant=np.rint(np.clip(new,0,1)*65535).astype('<u2');assert np.array_equal(quant[:,3],np.rint(colors[:,3]*65535).astype('<u2'))
  binary.extend(b'\0'*((-len(binary))%4));offset=len(binary);payload=quant.tobytes();binary.extend(payload);doc['bufferViews'].append({'buffer':0,'byteOffset':offset,'byteLength':len(payload)});doc['accessors'].append({'bufferView':len(doc['bufferViews'])-1,'componentType':5123,'normalized':True,'count':len(quant),'type':'VEC4'});attrs['COLOR_0']=len(doc['accessors'])-1;changed.append(m['name'])
doc['buffers'][0]['byteLength']=len(binary);binary.extend(b'\0'*((-len(binary))%4));encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4);target=struct.pack('<4sII',b'glTF',2,28+len(encoded)+len(binary))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+struct.pack('<I4s',len(binary),b'BIN\0')+binary;(out/'continuous-blink.vrm').write_bytes(target)
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'))
for name in changed:
 obj=bpy.data.objects[name];mesh=obj.data;c=mesh.color_attributes['SkinTint'];xyz=np.array([[v.co.x,v.co.z,-v.co.y] for v in mesh.vertices]);loops=np.array([l.vertex_index for l in mesh.loops]);rgba=np.array([v.color for v in c.data]);cx,coefs=fits[name.split()[2]];new=clean(xyz[loops],rgba,cx,coefs)
 for datum,color in zip(c.data,new):datum.color=color
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
report={'sourceSha256':hashlib.sha256(raw).hexdigest(),'outputSha256':hashlib.sha256(target).hexdigest(),'changedLids':changed,'fit':reports,'scope':'only RGB of four pink-lid COLOR_0 accessors; alpha, source face, ink, geometry, UV, normals, images and all expressions retained'};(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
