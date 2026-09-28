"""Remove a local highlight shading stain by fitting normals; keep all images intact."""
import bpy,copy,hashlib,json,os,struct
from pathlib import Path
import numpy as np
root=Path(__file__).resolve().parents[1];source=root/'artifacts/blink-aligned';suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ('','-repeat')
side=os.environ.get('HIGHLIGHT_SIDE','R');assert side in ('L','R')
out=root/'artifacts'/('highlight-clean-'+side.lower()+suffix);out.mkdir(exist_ok=True)
raw=(source/'continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0];original=json.loads(raw[20:20+n]);doc=copy.deepcopy(original);binary=bytearray(raw[28+n:]);source_binary=bytes(binary)
assert hashlib.sha256(raw).hexdigest()==json.loads((source/'report.json').read_text())['outputSha256']
def read(i):
 a=doc['accessors'][i];v=doc['bufferViews'][a['bufferView']];return np.frombuffer(source_binary,dtype='<f4',count=a['count']*{'VEC2':2,'VEC3':3}[a['type']],offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(a['count'],-1).copy()
mi=next(i for i,m in enumerate(doc['materials']) if m['name']==f'Original eye material {side}');primitive=next(p for m in doc['meshes'] for p in m['primitives'] if p['material']==mi);attrs=primitive['attributes'];xyz=read(attrs['POSITION']);uv=read(attrs['TEXCOORD_0']);normal=read(attrs['NORMAL'])
ti=doc['materials'][mi]['pbrMetallicRoughness']['baseColorTexture']['index'];im=doc['images'][doc['textures'][ti]['source']];bv=doc['bufferViews'][im['bufferView']];image_path=out/'source-basecolor.jpg';image_path.write_bytes(source_binary[bv.get('byteOffset',0):bv.get('byteOffset',0)+bv['byteLength']]);image=bpy.data.images.load(str(image_path),check_existing=False);w,h=image.size;rgba=np.empty(w*h*4,np.float32);image.pixels.foreach_get(rgba);pixels=rgba.reshape(h,w,4)[::-1,:,:3]*255;bpy.data.images.remove(image)
colors=pixels[np.clip((uv[:,1]*h).astype(int),0,h-1),np.clip((uv[:,0]*w).astype(int),0,w-1)]
white=colors.min(1)>160;assert 20<int(white.sum())<100
center=xyz[white].mean(0);delta=(xyz[:,:2]-center[:2])/.10
black=(colors.max(1)<100)&(np.linalg.norm(delta,axis=1)<1.1)
x,y=delta[black].T;design=np.stack([np.ones_like(x),x,y,x*x,x*y,y*y],axis=1);coef=np.linalg.lstsq(design,xyz[black,2],rcond=None)[0]
x,y=delta[white].T;fitted=np.stack([-(coef[1]+2*coef[3]*x+coef[4]*y)/.10,-(coef[2]+coef[4]*x+2*coef[5]*y)/.10,np.ones_like(x)],axis=1);fitted/=np.linalg.norm(fitted,axis=1)[:,None];normal[white]=fitted
binary.extend(b'\0'*((-len(binary))%4));offset=len(binary);payload=normal.astype('<f4').tobytes();binary.extend(payload);doc['bufferViews'].append({'buffer':0,'byteOffset':offset,'byteLength':len(payload)});doc['accessors'].append({'bufferView':len(doc['bufferViews'])-1,'componentType':5126,'count':len(normal),'type':'VEC3'});attrs['NORMAL']=len(doc['accessors'])-1;doc['buffers'][0]['byteLength']=len(binary)
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4);binary.extend(b'\0'*((-len(binary))%4));target=struct.pack('<4sII',b'glTF',2,28+len(encoded)+len(binary))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+struct.pack('<I4s',len(binary),b'BIN\0')+binary
(out/'continuous-blink.vrm').write_bytes(target)
# The same local normal edit in the copied authoring blend, including its split corners.
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'));obj=bpy.data.objects['Miineko_Body'];mesh=obj.data;normals=[tuple(v.vector) for v in mesh.corner_normals];highlight_xyz=xyz[white].astype(float);highlight_normals=normal[white];changed=0;matched=set();distances=[]
for poly in mesh.polygons:
 if mesh.materials[poly.material_index].name!=f'Original eye material {side}':continue
 for li in poly.loop_indices:
  p=mesh.vertices[mesh.loops[li].vertex_index].co;point=np.array([p.x,p.z,-p.y]);dist=np.linalg.norm(highlight_xyz-point,axis=1);i=int(dist.argmin())
  if dist[i]<2e-6:
   v=highlight_normals[i];normals[li]=(v[0],-v[2],v[1]);changed+=1;matched.add(tuple(np.rint(highlight_xyz[i]*1e5).astype(int)));distances.append(float(dist[i]))
assert len(matched)==len(set(map(tuple,np.rint(highlight_xyz*1e5).astype(int))))
assert changed>0;mesh.normals_split_custom_set(normals);bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
report={'sourceSha256':hashlib.sha256(raw).hexdigest(),'outputSha256':hashlib.sha256(target).hexdigest(),'material':f'Original eye material {side}','highlightVertices':int(white.sum()),'fitVertices':int(black.sum()),'changedBlendCorners':changed,'maxBlendMatchDistance':max(distances),'sourceBinaryPrefixUnchanged':bytes(binary[:len(source_binary)])==source_binary,'imagesAndPositionsUnchanged':True,'scope':'only normal accessor values at white-highlight vertices; texture pixels, UVs, geometry, expression binds and opposite eye retained'};(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
