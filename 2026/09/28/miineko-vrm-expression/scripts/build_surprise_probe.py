"""Append fixed side masks for a modest taller-looking eye; preserve source GLB data."""
import copy, hashlib, io, json, os, struct
from pathlib import Path
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1]
suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ('','-repeat')
source=root/'artifacts/eye-emotions-steeper'
raw=(source/'continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0]
original=json.loads(raw[20:20+n]);doc=copy.deepcopy(original);binary=bytearray(raw[28+n:])
assert hashlib.sha256(raw).hexdigest()==json.loads((source/'report.json').read_text())['outputSha256']
original_binary=bytes(binary)
def append(data):
 binary.extend(b'\0'*((-len(binary))%4));offset=len(binary);binary.extend(data)
 doc['bufferViews'].append({'buffer':0,'byteOffset':offset,'byteLength':len(data)})
 return len(doc['bufferViews'])-1
def array(index):
 a=doc['accessors'][index];v=doc['bufferViews'][a['bufferView']]
 assert 'byteStride' not in v
 size={'VEC3':3,'VEC2':2,'VEC4':4}[a['type']]
 dtype={5126:'<f4',5123:'<u2'}[a['componentType']]
 result=np.frombuffer(original_binary,dtype=dtype,count=a['count']*size,offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(-1,size).astype('<f4')
 if a.get('normalized'):result/=65535
 return result
def accessor(a,kind):
 doc['accessors'].append({'bufferView':append(a.astype('<f4').tobytes()),'componentType':5126,'count':len(a),'type':kind,'min':a.min(0).tolist(),'max':a.max(0).tolist()})
 return len(doc['accessors'])-1
u=(np.arange(1024)+.5)/1024;t=np.clip((abs(u-.5)-.2)/.0015,0,1);alpha=np.rint(t*t*(3-2*t)*255).astype('uint8')
rgba=np.full((4,1024,4),255,dtype='uint8');rgba[:,:,3]=alpha
png=io.BytesIO();Image.fromarray(rgba).save(png,format='PNG')
doc['images'].append({'name':'Surprise side reveal','mimeType':'image/png','bufferView':append(png.getvalue())})
doc['samplers'].append({'magFilter':9729,'minFilter':9729,'wrapS':33071,'wrapT':33071})
doc['textures'].append({'source':len(doc['images'])-1,'sampler':len(doc['samplers'])-1});texture=len(doc['textures'])-1
binds=[]
for side,cx in [('L',.1764),('R',-.1848)]:
 mi=next(i for i,m in enumerate(original['meshes']) if m['name']==f'Surface Lid {side} upper')
 m=copy.deepcopy(original['meshes'][mi]);m['name']=f'Surprise side mask {side}'
 for p in m['primitives']:
  xyz=array(p['attributes']['POSITION']);ink=next(mm for mm in original['meshes'] if mm['name']==f'Surface Lid {side} upper ink')['primitives'][0]['attributes']
  inkxyz=array(ink['POSITION']);inkxyz[:,2]-=.0002;inkcolors=array(ink['COLOR_0'])
  lookup={tuple(v[:2]):float(c[3]) for v,c in zip(inkxyz,inkcolors)}
  colors=array(p['attributes']['COLOR_0']);colors[:,3]=[lookup[tuple(v[:2])] for v in xyz]
  assert (colors[:,3]>0).sum()>1000
  p['attributes']['COLOR_0']=accessor(colors,'VEC4')
  uv=np.zeros((len(xyz),2),dtype='<f4')
  dz=(xyz[:,1]-.619)/.14
  q=(xyz[:,0]-cx)/(.104*np.sqrt(np.maximum(.08,1-dz*dz)))
  uv[:,0]=.5+.2*np.clip(q,-.95,.95);uv[:,1]=.5
  p['attributes']['TEXCOORD_0']=accessor(uv,'VEC2')
  xyz[:,2]+=.00005;p['attributes']['POSITION']=accessor(xyz,'VEC3')
  mat=copy.deepcopy(original['materials'][p['material']]);mat['name']=m['name'];mat['alphaMode']='MASK';mat['alphaCutoff']=.01;mat['pbrMetallicRoughness']['baseColorTexture']['index']=texture
  doc['materials'].append(mat);p['material']=len(doc['materials'])-1
  binds.append({'material':p['material'],'scale':[1.35,1],'offset':[-.175,0]})
 doc['meshes'].append(m)
 ni=next(i for i,node in enumerate(original['nodes']) if node.get('mesh')==mi)
 node=copy.deepcopy(original['nodes'][ni]);node['mesh']=len(doc['meshes'])-1;node['name']=m['name'];doc['nodes'].append(node);new_index=len(doc['nodes'])-1
 parents=[i for i,node in enumerate(original['nodes']) if ni in node.get('children',[])]
 if parents:
  for parent in parents:doc['nodes'][parent]['children'].append(new_index)
 else:
  for scene in doc['scenes']:
   if ni in scene.get('nodes',[]):scene['nodes'].append(new_index)
presets=doc['extensions']['VRMC_vrm']['expressions']['preset'];assert not presets['surprised'].get('textureTransformBinds')
presets['surprised']={**presets['surprised'],'textureTransformBinds':binds}
assert bytes(binary[:len(original_binary)])==original_binary
assert all(presets[k]==v for k,v in original['extensions']['VRMC_vrm']['expressions']['preset'].items() if k!='surprised')
doc['buffers'][0]['byteLength']=len(binary);binary.extend(b'\0'*((-len(binary))%4))
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
target=struct.pack('<4sII',b'glTF',2,28+len(encoded)+len(binary))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+struct.pack('<I4s',len(binary),b'BIN\0')+binary
out=root/'artifacts'/('surprise-eyes'+suffix);out.mkdir(exist_ok=True);(out/'continuous-blink.vrm').write_bytes(target)
report={'sourceSha256':hashlib.sha256(raw).hexdigest(),'outputSha256':hashlib.sha256(target).hexdigest(),'originalBinaryPrefixUnchanged':True,'existingExpressionsUnchanged':True,'sideMaskScale':1.35,'scope':'fixed pink side masks, narrower eye appearance only; original head, eye artwork and highlight unchanged; no authoring blend at this GLB assembly stage'}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
