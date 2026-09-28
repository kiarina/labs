"""Expression-direction probe: fixed lids on the revised eyes, no head deformation."""
import bpy,numpy as np,math,json,hashlib,os,struct
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree
root=Path(__file__).resolve().parents[1];source=root/'artifacts/mouth-connected-vowels'
suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ['', '-repeat']
normal_mode=os.environ.get('LID_NORMALS','skin-fit');assert normal_mode in ['skin-fit','source']
style=os.environ.get('EXPRESSION_STYLE','original');assert style in ['original','rounded']
rounded=style=='rounded'
assert not (rounded and normal_mode=='source'), 'Keep the shading control separate from the rounded-smile study'
out=root/'artifacts'/(('rounded-smile' if rounded else 'surface-expressions')+('-source' if normal_mode=='source' else '')+suffix);out.mkdir(exist_ok=True)
expected=json.loads((source/'report.json').read_text())['outputSha256'];assert hashlib.sha256((source/'continuous-blink.vrm').read_bytes()).hexdigest()==expected
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'))
body=bpy.data.objects['Miineko_Body'];arm=bpy.data.objects['Miineko_Rig'];mesh=body.data;mesh.calc_loop_triangles()
pos=np.array([v.co for v in mesh.vertices]);tris=np.array([list(t.vertices) for t in mesh.loop_triangles]);loops=np.array([list(t.loops) for t in mesh.loop_triangles]);uv0=np.array([l.uv for l in mesh.uv_layers[0].data]);norm0=np.array([n.vector for n in mesh.corner_normals])
image=next(n.image for n in mesh.materials[0].node_tree.nodes if n.type=='TEX_IMAGE' and n.image and 'BaseColor' in n.image.filepath);iw,ih=image.size;pixels=np.empty(iw*ih*4,np.float32);image.pixels.foreach_get(pixels);pixels=pixels.reshape(ih,iw,4)
bvh=BVHTree.FromPolygons([Vector(p) for p in pos],tris.tolist(),all_triangles=True)
def smooth(t):t=np.clip(t,0,1);return t*t*(3-2*t)
def linear(c):return np.where(c<=.04045,c/12.92,((c+.055)/1.055)**2.4)
def rgb(st):return pixels[min(ih-1,max(0,int(st[1]*ih))),min(iw-1,max(0,int(st[0]*iw))),:3]
def sample(x,z):
 hit,_,ti,_=bvh.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))
 if hit is None:return None
 a,b,c=pos[tris[ti]];weights=np.linalg.lstsq(np.stack([b-a,c-a],axis=1),np.array(hit)-a,rcond=None)[0];uv=uv0[loops[ti]];return rgb(uv[0]+weights[0]*(uv[1]-uv[0])+weights[1]*(uv[2]-uv[0]))
def clip(poly,fn):
 result=[]
 for a,b in zip(poly,poly[1:]+poly[:1]):
  da,db=fn(a),fn(b)
  if da>=0:result.append(a)
  if (da>=0)!=(db>=0):result.append(a+(b-a)*da/(da-db))
 return result
presets=arm.data.vrm_addon_extension.vrm1.expressions.preset
for name in ['happy','relaxed','blink','blink_left','blink_right']:
 e=getattr(presets,name)
 for binds in [e.morph_target_binds,e.texture_transform_binds,e.material_color_binds]:binds.clear()
 e.is_binary=False;e.override_blink='none';e.override_mouth='none';e.override_look_at='none'
# Distances refer to Blender coordinates. The small lower/upper overlap hides
# the alpha transition at complete closure; the upper lid carries the ink line.
shapes={'blink':{'upper':(.87-.619,1),'lower':(.622-.37,1)},'happy':{'upper':(.87-.650,math.sqrt(.030/.004)),'lower':(.653-.37,math.sqrt(.030/.004))},'relaxed':{'upper':(.87-.660,1),'lower':(0,1)}}
upper_origin=.78 if rounded else .87;lower_origin=.45 if rounded else .37
if rounded:
 shapes={'blink':{'upper':(upper_origin-.619,1),'lower':(.622-lower_origin,1)},'happy':{'upper':(upper_origin-.646,5.5),'lower':(.649-lower_origin,5.5)},'relaxed':{'upper':(upper_origin-.660,1),'lower':(0,1)}}
report={'expressionStyle':'rounded' if rounded else 'original','lidNormalMode':normal_mode,'sourceSha256':expected,'scope':'expression-direction probe on fixed revised-eye surface; no source head deformation','eyes':{},'shapes':shapes}
for side,cx in [('L',.1764),('R',-.1848)]:
 cz=.619;rx=.104;rz=.113;samples=[]
 for radius in [1.10,1.22,1.35]:
  for angle in np.linspace(0,2*math.pi,96,endpoint=False):
   x,z=cx+rx*radius*math.cos(angle),cz+rz*radius*math.sin(angle);c=sample(x,z)
   if c is not None and c[0]>.6 and c[1]<.3 and c[2]>.2:samples.append((x,z,linear(c)))
 assert len(samples)>40
 sample_xz=np.array([[x,z] for x,z,c in samples]);sample_rgb=np.array([c for x,z,c in samples]);su=(sample_xz[:,0]-cx)/rx;sv=(sample_xz[:,1]-cz)/rz;design=np.stack([np.ones_like(su),su,sv,su*su,su*sv,sv*sv],axis=1);ys=np.array([bvh.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))[0].y for x,z in sample_xz]);coeff=np.linalg.lstsq(design,ys,rcond=None)[0]
 verts=[];normals=[];colors=[];ink_mask=[];faces=[];parents=[];lookup={};xs=np.linspace(cx-rx*1.24,cx+rx*1.24,81)
 for ti,ids in enumerate(tris):
  points=pos[ids]
  if points[:,1].min()>-.1 or points[:,0].min()>xs[-1] or points[:,0].max()<xs[0] or points[:,2].max()<cz-rz*1.24 or points[:,2].min()>cz+rz*1.24:continue
  lo=max(0,np.searchsorted(xs,points[:,0].min(),side='right')-1);hi=min(len(xs)-2,np.searchsorted(xs,points[:,0].max()))
  for i in range(lo,hi+1):
   poly=[np.concatenate([p,st,n]) for p,st,n in zip(points,uv0[loops[ti]],norm0[loops[ti]])]
   for fn in [lambda p:p[0]-xs[i],lambda p:xs[i+1]-p[0],lambda p:p[2]-(cz-rz*1.24),lambda p:cz+rz*1.24-p[2]]:
    poly=clip(poly,fn)
    if len(poly)<3:break
   if len(poly)<3:continue
   polygon=[]
   for p in poly:
    key=tuple(np.round(p,8))
    if key not in lookup:
     idx=len(verts);lookup[key]=idx;verts.append(p[:3]);normal=p[5:];normals.append(normal/max(1e-12,np.linalg.norm(normal)))
     x,z=p[0],p[2];r=math.hypot((x-cx)/rx,(z-cz)/rz);alpha=float(1-smooth((r-1.02)/.20));alpha*=float(1-smooth((abs((x-cx)/rx)-.90)/.16))
     if normal_mode=='skin-fit':
      u,v=(x-cx)/rx,(z-cz)/rz;fitted=np.array([(coeff[1]+2*coeff[3]*u+coeff[4]*v)/rx,-1,(coeff[2]+coeff[4]*u+2*coeff[5]*v)/rz]);fitted/=np.linalg.norm(fitted);normal=fitted*alpha+np.array(normals[-1])*(1-alpha);normals[-1]=normal/np.linalg.norm(normal)
     c=rgb(p[3:5]);pink=c[0]>.6 and c[1]<.3 and c[2]>.2
     if pink:c=linear(c)
     else:
      weights=1/(.002+((sample_xz-[x,z])**2).sum(1));c=np.sum(sample_rgb*weights[:,None],axis=0)/weights.sum()
     original_color=rgb(p[3:5]);is_skin=original_color[0]>max(.08,1.6*original_color[1]) and original_color[2]>max(.035,1.2*original_color[1]);ink_mask.append(0. if is_skin else alpha)
     colors.append((*c,alpha))
    polygon.append(lookup[key])
   for j in range(1,len(polygon)-1):
    t=(polygon[0],polygon[j],polygon[j+1])
    if len(set(t))==3 and np.linalg.norm(np.cross(np.array(verts[t[1]])-verts[t[0]],np.array(verts[t[2]])-verts[t[0]]))>1e-12:faces.append(t);parents.append(ti)
 report['eyes'][side]={'verticesPerLid':len(verts),'trianglesPerLid':len(faces),'skinSamples':len(samples)}
 for direction,label,origin,offset in [(1,'upper',upper_origin,.0007),(-1,'lower',lower_origin,.0004)]:
  name=f'Surface Lid {side} {label}';data=bpy.data.meshes.new(name);xyz=np.array(verts);xyz[:,1]-=offset;data.from_pydata(xyz.tolist(),[],faces);data.update();obj=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(obj);obj.parent=arm;vg=obj.vertex_groups.new(name='J_Bip_C_Head');vg.add(list(range(len(verts))),1,'REPLACE');obj.modifiers.new('Armature','ARMATURE').object=arm
  for p in data.polygons:p.use_smooth=True
  data.normals_split_custom_set([normals[l.vertex_index] for l in data.loops])
  uv=data.uv_layers.new(name='ExpressionReveal');attr=data.color_attributes.new(name='SkinTint',type='FLOAT_COLOR',domain='CORNER');data.color_attributes.active_color=attr
  for loop in data.loops:
   p=verts[loop.vertex_index];uv.data[loop.index].uv=(.5+(p[0]-cx)/((16 if rounded else 8)*rx),.5+3*direction*(p[2]-origin));attr.data[loop.index].color=colors[loop.vertex_index]
  w=h=2048;u=(np.arange(w)+.5)/w;v=(np.arange(h)+.5)/h;q=(16 if rounded else 8)*(u-.5)
  distance=v[:,None]-.5+direction*3*.004*q[None,:]**2;alpha=smooth(distance/.0015)
  ink=(1-smooth((distance-.018)/.006))*(1-smooth((abs(q)[None,:]-1.40)/.25)) if direction==1 else np.zeros_like(distance)
  if rounded and direction==1:
   # Rounded caps around a short parabolic stroke, independent of the reveal alpha.
   cap_distance=np.sqrt(np.maximum(abs(q)[None,:]-2.50,0)**2*.04**2+(distance-.015)**2)
   ink=1-smooth((cap_distance-.0135)/.003)
  rgba=np.ones((h,w,4),np.float32);rgba[:,:,:3]=(1-.997*ink)[:,:,None];rgba[:,:,3]=alpha
  stroke_rgba=rgba.copy() if rounded and direction==1 else None
  if stroke_rgba is not None:
   stroke_rgba[:,:,:3]=.003;stroke_rgba[:,:,3]=alpha*ink;rgba[:,:,:3]=1
  im=bpy.data.images.new(name,width=w,height=h,alpha=True);im.pixels.foreach_set(rgba.ravel());im.filepath_raw=str(out/f'{side}-{label}.png');im.file_format='PNG';im.save();im=bpy.data.images.load(im.filepath_raw,check_existing=False);im.pack()
  mat=bpy.data.materials.new(name);mat.use_nodes=True;mat.surface_render_method='BLENDED';mat.use_backface_culling=True;n=mat.node_tree.nodes;l=mat.node_tree.links;bs=next(n for n in n if n.type=='BSDF_PRINCIPLED');bs.inputs['Roughness'].default_value=.9
  tex=n.new('ShaderNodeTexImage');tex.image=im;tex.extension='EXTEND';coord=n.new('ShaderNodeTexCoord');mapping=n.new('ShaderNodeMapping');mapping.vector_type='POINT';l.new(coord.outputs['UV'],mapping.inputs['Vector']);l.new(mapping.outputs['Vector'],tex.inputs['Vector']);color=n.new('ShaderNodeVertexColor');color.layer_name='SkinTint';tint=n.new('ShaderNodeMix');tint.data_type='RGBA';tint.blend_type='MULTIPLY';tint.inputs[0].default_value=1;l.new(tex.outputs['Color'],tint.inputs[6]);l.new(color.outputs['Color'],tint.inputs[7]);l.new(tint.outputs[2],bs.inputs['Base Color']);mul=n.new('ShaderNodeMath');mul.operation='MULTIPLY';l.new(tex.outputs['Alpha'],mul.inputs[0]);l.new(color.outputs['Alpha'],mul.inputs[1]);l.new(mul.outputs[0],bs.inputs['Alpha']);data.materials.append(mat)
  for expression,settings in shapes.items():
   depth,scale=settings[label]
   for target in [expression]+([('blink_left' if side=='L' else 'blink_right')] if expression=='blink' else []):
    bind=getattr(presets,target).texture_transform_binds.add();bind.material=mat;bind.scale=(scale,1);bind.offset=((1-scale)/2,-3*depth)
  if stroke_rgba is not None:
   # Keep moving ink on the original eye artwork, so it cannot become a
   # detached eyebrow while the lid is still above the open eye.
   stroke_name=name+' ink';stroke_mesh=data.copy();stroke_mesh.name=stroke_name
   for vertex in stroke_mesh.vertices:vertex.co.y-=.0002
   stroke_obj=obj.copy();stroke_obj.data=stroke_mesh;stroke_obj.name=stroke_name;bpy.context.collection.objects.link(stroke_obj)
   stroke_colors=stroke_mesh.color_attributes['SkinTint']
   for loop in stroke_mesh.loops:stroke_colors.data[loop.index].color=(1,1,1,ink_mask[loop.vertex_index])
   stroke_mat=mat.copy();stroke_mat.name=stroke_name;stroke_mesh.materials.clear();stroke_mesh.materials.append(stroke_mat)
   sim=bpy.data.images.new(stroke_name,width=w,height=h,alpha=True);sim.pixels.foreach_set(stroke_rgba.ravel());sim.filepath_raw=str(out/f'{side}-upper-ink.png');sim.file_format='PNG';sim.save();sim=bpy.data.images.load(sim.filepath_raw,check_existing=False);sim.pack()
   next(n for n in stroke_mat.node_tree.nodes if n.type=='TEX_IMAGE').image=sim
   for expression,settings in shapes.items():
    depth,scale=settings['upper']
    for target in [expression]+([('blink_left' if side=='L' else 'blink_right')] if expression=='blink' else []):
     bind=getattr(presets,target).texture_transform_binds.add();bind.material=stroke_mat;bind.scale=(scale,1);bind.offset=((1-scale)/2,-3*depth)
   ink_xyz=np.array([v.co for v in stroke_mesh.vertices]);np.savez_compressed(out/f'audit-{side}-ink.npz',source=pos,sourceTriangles=tris,opening=ink_xyz,openingTriangles=np.array(faces),parentTriangle=np.array(parents),offset=np.array([0,-offset-.0002,0]))
  np.savez_compressed(out/f'audit-{side}-{label}.npz',source=pos,sourceTriangles=tris,opening=xyz,openingTriangles=np.array(faces),parentTriangle=np.array(parents),offset=np.array([0,-offset,0]))
assert np.array_equal(pos,np.array([v.co for v in body.data.vertices]))
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'));assert bpy.ops.export_scene.vrm(filepath=str(out/'continuous-blink.vrm'))=={'FINISHED'}
path=out/'continuous-blink.vrm';raw=path.read_bytes();size=struct.unpack_from('<I',raw,12)[0];doc=json.loads(raw[20:20+size]);tail=raw[20+size:];patched=[]
for gm in doc['meshes']:
 if gm['name']=='Connected AA surface' or gm['name'].startswith('Surface Lid'):
  for p in gm['primitives']:
   attrs=p['attributes']
   if 'COLOR_1' in attrs:attrs['COLOR_0']=attrs.pop('COLOR_1')
   mat=doc['materials'][p['material']];tex=doc['textures'][mat['pbrMetallicRoughness']['baseColorTexture']['index']];sampler=dict(doc['samplers'][tex['sampler']]);sampler.update(minFilter=9729,magFilter=9729);tex['sampler']=len(doc['samplers']);doc['samplers'].append(sampler);patched.append(gm['name'])
assert len(patched)==(7 if rounded else 5)
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4);path.write_bytes(struct.pack('<4sII',b'glTF',2,20+len(encoded)+len(tail))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+tail)
report.update(sourceBodyUnchanged=True,fixedLidOffsets=([.0007,.0004,.0009] if rounded else [.0007,.0004]),patchedMaterials=patched,outputSha256=hashlib.sha256(path.read_bytes()).hexdigest());(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
