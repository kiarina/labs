"""A surface-following AA opening with a lower contour joined to the source W.

The stamp sheet guides the red fill and bold contour. The approved closed face
is unchanged. Opening uses a standard VRM texture-transform reveal on a fixed
surface, so interpolation does not lift the mouth off the curved head.
"""
import bpy,numpy as np,math,json,hashlib,os,struct,sys
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'scripts'))
from source_ink import SourceInk
source=root/'artifacts/feature-mouth-flush';suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ['', '-repeat']
out=root/'artifacts'/('mouth-connected-aa'+suffix);out.mkdir(exist_ok=True)
expected='989f33cb81f91a99e2112fb9ce7df47e2734096d649519950f371cdddbc99665'
assert hashlib.sha256((source/'continuous-blink.vrm').read_bytes()).hexdigest()==expected
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'))
body=bpy.data.objects['Miineko_Body'];arm=bpy.data.objects['Miineko_Rig'];body.data.calc_loop_triangles()
original=np.array([v.co for v in body.data.vertices]);indices=np.array([list(t.vertices) for t in body.data.loop_triangles]);source_loops=np.array([list(t.loops) for t in body.data.loop_triangles]);source_uv=np.array([l.uv for l in body.data.uv_layers[0].data])
head=BVHTree.FromPolygons([Vector(p) for p in original],indices.tolist(),all_triangles=True);ink=SourceInk(body,head)
def face(x,z):return ink.sample(float(x),float(z))
# Keep the source W as the upper contour, including its original width.
width=.074;cols=161;xs=np.linspace(-width,width,cols);upper=[]
for x in xs:
 prior=.477-.032*math.sin(math.pi*min(1,abs(x)/.081))
 dark=[z for z in np.linspace(prior-.012,prior+.012,81) if face(x,z)[1]]
 if not dark:raise ValueError(f'Missing source W at {x}')
 upper.append(float(np.median(dark)))
upper=np.array(upper)
for _ in range(3):old=upper.copy();upper[1:-1]=.25*old[:-2]+.5*old[1:-1]+.25*old[2:]
# The revealing boundary is a rounded U without a central lower-lip peak.
start=.479;travel=.089;corner_rise=.078;scale=3.;shift=scale*travel
verts=[];faces=[];uvs=[];vertex_alpha=[];lookup={};parents=[]
def clip(poly,fn):
 result=[]
 for a,b in zip(poly,poly[1:]+poly[:1]):
  da,db=fn(a),fn(b);inside_a=da>=-1e-10;inside_b=db>=-1e-10
  if inside_a:result.append(a)
  if inside_a!=inside_b:result.append(a+(b-a)*(da/(da-db)))
 return result
# Clip source triangles to narrow X strips and the opening outline. This retains
# the actual head surface rather than approximating its depth on an unrelated grid.
for ti,ids in enumerate(indices):
 points=original[ids]
 if points[:,1].min()>-.1 or points[:,0].min()>width or points[:,0].max()<-width or points[:,2].max()<start-travel-.003 or points[:,2].min()>upper.max():continue
 low=max(0,int(np.searchsorted(xs,points[:,0].min(),side='right')-1));high=min(cols-2,int(np.searchsorted(xs,points[:,0].max())))
 for i in range(low,high+1):
  x0,x1=xs[i:i+2];top0,top1=upper[i:i+2]
  bottom0=start-travel+corner_rise*(x0/width)**2-.002;bottom1=start-travel+corner_rise*(x1/width)**2-.002
  poly=[np.concatenate([p,st]).astype(float) for p,st in zip(points,source_uv[source_loops[ti]])]
  for fn in [lambda p:p[0]-x0,lambda p:x1-p[0],lambda p:top0+(top1-top0)*(p[0]-x0)/(x1-x0)-p[2],lambda p:p[2]-(bottom0+(bottom1-bottom0)*(p[0]-x0)/(x1-x0))]:
   poly=clip(poly,fn)
   if len(poly)<3:break
  if len(poly)<3:continue
  polygon=[]
  for point in poly:
   x,y,z=point[:3];key=tuple(np.round(point,8))
   if key not in lookup:
    lookup[key]=len(verts);verts.append((x,y-.0007,z));uvs.append((.5,.5+scale*(z-start-corner_rise*(x/width)**2)));u0,v0=point[3:];c=ink.pixels[min(ink.height-1,max(0,int(v0*ink.height))),min(ink.width-1,max(0,int(u0*ink.width))),:3];vertex_alpha.append(0. if c.max()<.25 else 1.)
   polygon.append(lookup[key])
  for j in range(1,len(polygon)-1):
   t=(polygon[0],polygon[j],polygon[j+1])
   if len(set(t))==3 and np.linalg.norm(np.cross(np.array(verts[t[1]])-verts[t[0]],np.array(verts[t[2]])-verts[t[0]]))>1e-12:faces.append(t);parents.append(ti)
mesh=bpy.data.meshes.new('Connected AA surface');mesh.from_pydata(verts,[],faces);mesh.update();obj=bpy.data.objects.new('Mouth_Connected_AA',mesh);bpy.context.collection.objects.link(obj);obj.parent=arm
vg=obj.vertex_groups.new(name='J_Bip_C_Head');vg.add(list(range(len(verts))),1,'REPLACE');obj.modifiers.new('Armature','ARMATURE').object=arm
for p in mesh.polygons:p.use_smooth=True
uv=mesh.uv_layers.new(name='AA_Reveal')
colors=mesh.color_attributes.new(name='SourceInkMask',type='FLOAT_COLOR',domain='CORNER');mesh.color_attributes.active_color=colors
for loop in mesh.loops:
 uv.data[loop.index].uv=uvs[loop.vertex_index];colors.data[loop.index].color=(1,1,1,vertex_alpha[loop.vertex_index])
# A procedural 1-D palette: transparent, then black lower rim, then red interior.
height=4096;v=(np.arange(height)+.5)/height
smooth=lambda x: np.clip(x,0,1)**2*(3-2*np.clip(x,0,1))
alpha=smooth((v-.5)/.0015);red=smooth((v-(.5+scale*.010))/ (scale*.002))
black=np.array((.002,.0007,.0015));fill=np.array((.52,.003,.015));rgb=black[None,:]*(1-red[:,None])+fill[None,:]*red[:,None];rgb=np.where(rgb<=.0031308,12.92*rgb,1.055*rgb**(1/2.4)-.055)
rgba=np.ones((height,8,4),np.float32);rgba[:,:,:3]=rgb[:,None,:];rgba[:,:,3]=alpha[:,None]
image=bpy.data.images.new('Connected AA reveal',width=8,height=height,alpha=True);image.pixels.foreach_set(rgba.ravel());image.filepath_raw=str(out/'aa-reveal.png');image.file_format='PNG';image.save();image=bpy.data.images.load(image.filepath_raw,check_existing=False);image.pack()
mat=bpy.data.materials.new('Connected AA red and rim');mat.use_nodes=True;mat.surface_render_method='BLENDED';mat.use_backface_culling=False;nodes=mat.node_tree.nodes;links=mat.node_tree.links;nodes.clear()
output=nodes.new('ShaderNodeOutputMaterial');coord=nodes.new('ShaderNodeTexCoord');mapping=nodes.new('ShaderNodeMapping');mapping.vector_type='POINT';tex=nodes.new('ShaderNodeTexImage');tex.image=image;tex.extension='EXTEND'
links.new(coord.outputs['UV'],mapping.inputs['Vector']);links.new(mapping.outputs['Vector'],tex.inputs['Vector']);transparent=nodes.new('ShaderNodeBsdfTransparent');mix=nodes.new('ShaderNodeMixShader');color=nodes.new('ShaderNodeVertexColor');color.layer_name='SourceInkMask';alpha_multiply=nodes.new('ShaderNodeMath');alpha_multiply.operation='MULTIPLY';links.new(tex.outputs['Alpha'],alpha_multiply.inputs[0]);links.new(color.outputs['Alpha'],alpha_multiply.inputs[1]);links.new(alpha_multiply.outputs[0],mix.inputs[0]);links.new(transparent.outputs[0],mix.inputs[1]);links.new(tex.outputs['Color'],mix.inputs[2]);links.new(mix.outputs[0],output.inputs['Surface']);mesh.materials.append(mat)
expr=arm.data.vrm_addon_extension.vrm1.expressions.preset.aa;expr.texture_transform_binds.clear();expr.morph_target_binds.clear();expr.material_color_binds.clear();expr.is_binary=False;expr.override_blink='none';expr.override_mouth='none';expr.override_look_at='none'
bind=expr.texture_transform_binds.add();bind.material=mat;bind.scale=(1,1);bind.offset=(0,-shift)
assert np.array_equal(original,np.array([v.co for v in body.data.vertices]))
np.savez_compressed(out/'surface-audit.npz',source=original,sourceTriangles=indices,opening=np.array([v.co for v in mesh.vertices]),openingTriangles=np.array(faces),parentTriangle=np.array(parents),offset=np.array([0,-.0007,0]))
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'));result=bpy.ops.export_scene.vrm(filepath=str(out/'continuous-blink.vrm'));assert result=={'FINISHED'}
path=out/'continuous-blink.vrm';raw=path.read_bytes();n=struct.unpack_from('<I',raw,12)[0];doc=json.loads(raw[20:20+n]);tail=raw[20+n:];m=next(m for m in doc['materials'] if m['name']==mat.name);texture=doc['textures'][m['pbrMetallicRoughness']['baseColorTexture']['index']];sampler=dict(doc['samplers'][texture['sampler']]);sampler.update(minFilter=9729,magFilter=9729);texture['sampler']=len(doc['samplers']);doc['samplers'].append(sampler)
# The exporter emits a dummy white COLOR_0 and the alpha mask in COLOR_1
# for this unlit alpha-node layout. Standard viewers consume COLOR_0.
patched=0
for gm in doc['meshes']:
 if gm.get('name')!=mesh.name:continue
 for primitive in gm['primitives']:
  attrs=primitive['attributes'];assert 'COLOR_1' in attrs
  accessor=doc['accessors'][attrs['COLOR_1']];assert accessor['type']=='VEC4'
  attrs['COLOR_0']=attrs.pop('COLOR_1');patched+=1
assert patched==1
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4);path.write_bytes(struct.pack('<4sII',b'glTF',2,20+len(encoded)+len(tail))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+tail)
report={'sourceSha256':expected,'sourceBodyUnchanged':True,'vertexAlphaPatchedToColor0':True,'sourceInkMaskThreshold':.25,'width':width,'sourceTrianglesClipped':True,'columns':cols,'vertices':len(verts),'triangles':len(faces),'start':start,'travel':travel,'cornerRise':corner_rise,'uvScale':scale,'shift':shift,'rimThickness':.010,'neutralMaximumUV':max(v for u,v in uvs),'scope':'fixed source-triangle opening with vertex alpha ink mask; AA-only; source W upper contour; no new eye/relaxed/vowel binds','upperCurve':upper.tolist(),'outputSha256':hashlib.sha256(path.read_bytes()).hexdigest()}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='upperCurve'}))
