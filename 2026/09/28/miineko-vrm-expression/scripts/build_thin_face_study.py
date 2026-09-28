"""Static form studies: local face smoothing and surface-following graphic features.

Source bitmaps stay unchanged. Skin cover colors are procedural vertex colors,
fit from clean surrounding source skin. These are not animation-ready candidates.
"""
import bpy, numpy as np, math, os, json, hashlib
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree
root=Path(__file__).resolve().parents[1]
source=root/'artifacts/mouth-aa-aligned'
expected='cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31'
assert hashlib.sha256((source/'continuous-blink.vrm').read_bytes()).hexdigest()==expected
variant=os.environ.get('FACE_STUDY','eyes-mouth');pose=os.environ.get('FACE_POSE','neutral')
assert variant in ['eyes','eyes-mouth'] and pose in ['neutral','smile']
suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ['', '-repeat']
out=root/'artifacts'/f'thin-{variant}-{pose}{suffix}';out.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'))
body=bpy.data.objects['Miineko_Body'];arm=bpy.data.objects['Miineko_Rig'];mesh=body.data
mesh.calc_loop_triangles();positions=np.array([v.co for v in mesh.vertices]);triangles=list(mesh.loop_triangles)
bvh=BVHTree.FromPolygons([v.co.copy() for v in mesh.vertices],[list(t.vertices) for t in triangles],all_triangles=True)
image=next(n.image for n in mesh.materials[0].node_tree.nodes if n.type=='TEX_IMAGE' and n.image and 'BaseColor' in n.image.filepath)
pixels=np.empty(image.size[0]*image.size[1]*4,np.float32);image.pixels.foreach_get(pixels);pixels=pixels.reshape(image.size[1],image.size[0],4)
uv=np.array([p.uv for p in mesh.uv_layers[0].data])
def sample(x,z):
 p,_,index,_=bvh.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))
 if p is None:raise ValueError((x,z))
 t=triangles[index];a,b,c=positions[list(t.vertices)];v0,v1,v2=b-a,c-a,np.array(p)-a
 d00,d01,d11=v0@v0,v0@v1,v1@v1;d20,d21=v2@v0,v2@v1;den=d00*d11-d01*d01
 wb=(d11*d20-d01*d21)/den;wc=(d00*d21-d01*d20)/den
 st=uv[list(t.loops)];u,v=st[0]*(1-wb-wc)+st[1]*wb+st[2]*wc
 color=pixels[min(image.size[1]-1,max(0,int(v*image.size[1]))),min(image.size[0]-1,max(0,int(u*image.size[0]))),:3]
 return p.y,color

def smooth(t):t=np.clip(t,0,1);return t*t*(3-2*t)
def linear(c):return np.where(c<=.04045,c/12.92,((c+.055)/1.055)**2.4)
eyes=[{'name':'eye-L','cx':.1764,'cz':.619,'rx':.14,'rz':.15},{'name':'eye-R','cx':-.1848,'cz':.619,'rx':.14,'rz':.15}]
regions=[{'name':'face','cx':0,'cz':.61,'rx':.36,'rz':.255}]
for r in regions:
 colors=[]
 for radius in [1.,1.08,1.16]:
  for angle in np.linspace(0,2*math.pi,72,endpoint=False):
   u,v=radius*math.cos(angle),radius*math.sin(angle);x,z=r['cx']+u*r['rx'],r['cz']+v*r['rz']
   try:y,c=sample(x,z)
   except ValueError:continue
   if not(c[0]>.65 and c[1]<.25 and c[2]>.2):continue
   colors.append(c)
 r['rgb']=linear(np.median(colors,axis=0))

def shape_y(x,z,y):
 for r in regions:
  u,v=(x-r['cx'])/r['rx'],(z-r['cz'])/r['rz'];radius=math.hypot(u,v)
  if radius<1.12:
   blend=1-float(smooth((radius-.76)/.36))
   if variant=='eyes':blend*=float(smooth((math.hypot(x/.108,(z-.49)/.078)-.85)/.4))
   target=.04-.31*math.sqrt(max(.025,1-(x/.445)**2-((z-.635)/.34)**2));y=y*(1-blend)+target*blend
 return y
# Every original vertex keeps x/z; only the affected front surface moves in depth.
body.shape_key_clear()
for p,original in zip(mesh.vertices,positions):
 if p.co.y<-.09:p.co.y=shape_y(p.co.x,p.co.z,p.co.y)
mesh.update();mesh.calc_loop_triangles()
fitted=BVHTree.FromPolygons([v.co.copy() for v in mesh.vertices],[list(t.vertices) for t in mesh.loop_triangles],all_triangles=True)
for o in list(bpy.data.objects):
 if o.type=='MESH' and o!=body:bpy.data.objects.remove(o,do_unlink=True)
presets=arm.data.vrm_addon_extension.vrm1.expressions.preset
for name in ['happy','relaxed','blink','blink_left','blink_right','aa','ih','ou','ee','oh']:
 e=getattr(presets,name)
 for binds in [e.morph_target_binds,e.texture_transform_binds,e.material_color_binds]:binds.clear()
 e.override_blink='none';e.override_mouth='none'

def material(name,color,unlit=False,vertex=False):
 m=bpy.data.materials.new(name);m.use_nodes=True;n=m.node_tree.nodes;l=m.node_tree.links;n.clear();output=n.new('ShaderNodeOutputMaterial')
 shader=n.new('ShaderNodeEmission' if unlit else 'ShaderNodeBsdfPrincipled')
 if unlit:shader.inputs['Color'].default_value=(*color,1)
 else:
  shader.inputs['Base Color'].default_value=(*color,1);shader.inputs['Roughness'].default_value=.85
 if vertex:
  node=n.new('ShaderNodeVertexColor');node.layer_name='StudyColor';l.new(node.outputs['Color'],shader.inputs['Base Color']);l.new(node.outputs['Alpha'],shader.inputs['Alpha']);m.surface_render_method='BLENDED'
 l.new(shader.outputs[0],output.inputs['Surface']);m.use_backface_culling=False;return m
pink=material('Surface skin',(.8,.005,.4),vertex=True);black=material('Graphic black',(.002,.002,.002),True);white=material('Graphic highlight',(.9,.9,.9),True)
def add_mesh(name,verts,faces,mat,colors=None):
 data=bpy.data.meshes.new(name);data.from_pydata(verts,[],faces);data.update();obj=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(obj);data.materials.append(mat)
 obj.parent=arm;g=obj.vertex_groups.new(name='J_Bip_C_Head');g.add(list(range(len(verts))),1,'REPLACE');obj.modifiers.new('Armature','ARMATURE').object=arm
 for p in data.polygons:p.use_smooth=True
 if colors is not None:
  attr=data.color_attributes.new(name='StudyColor',type='FLOAT_COLOR',domain='CORNER');data.color_attributes.active_color=attr
  for loop in data.loops:attr.data[loop.index].color=colors[loop.vertex_index]
 return obj

def surface(x,z,offset=.002):
 ideal=shape_y(x,z,sample(x,z)[0]);hit=fitted.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))[0]
 return min(ideal,hit.y if hit else ideal)-offset
for r in regions:
 n=65;verts=[];faces=[];colors=[]
 for j in range(n):
  for i in range(n):
   u,v=(i/(n-1)*2-1)*1.1,(j/(n-1)*2-1)*1.1;x,z=r['cx']+u*r['rx'],r['cz']+v*r['rz'];radius=math.hypot(u,v)
   try:y,c=sample(x,z)
   except ValueError:y=-.1
   try:depth=surface(x,z,.0025)
   except ValueError:depth=shape_y(x,z,y)-.0025
   verts.append((x,depth,z));alpha=1-float(smooth((radius-.76)/.29))
   if variant=='eyes':alpha*=float(smooth((math.hypot(x/.108,(z-.49)/.078)-.85)/.4))
   colors.append((*r['rgb'],alpha))
 for j in range(n-1):
  for i in range(n-1):
   a=j*n+i;faces.append((a,a+n,a+n+1,a+1))
 add_mesh('Skin '+r['name'],verts,faces,pink,colors)

def disk(name,cx,cz,rx,rz,mat,offset=.004):
 verts=[(cx,surface(cx,cz,offset),cz)];faces=[];rings=12;segments=80
 for j in range(1,rings+1):
  for i in range(segments):
   t=i/segments*2*math.pi;x=cx+rx*j/rings*math.cos(t);z=cz+rz*j/rings*math.sin(t);verts.append((x,surface(x,z,offset),z))
 for i in range(segments):faces.append((0,1+i,1+(i+1)%segments))
 for j in range(rings-1):
  for i in range(segments):
   a=1+j*segments+i;b=1+j*segments+(i+1)%segments;faces.append((a,b,b+segments,a+segments))
 return add_mesh(name,verts,faces,mat)
def stroke(name,points,width):
 verts=[];faces=[]
 for i,(x,z) in enumerate(points):
  a=np.array(points[max(0,i-1)]);b=np.array(points[min(len(points)-1,i+1)]);t=b-a;t=t/max(1e-10,np.linalg.norm(t));normal=np.array([-t[1],t[0]])
  taper=max(.05,math.sin(math.pi*i/(len(points)-1))**.3)
  for sign in [-1,1]:
   q=np.array([x,z])+normal*width*.5*taper*sign;verts.append((q[0],surface(*q,.0042),q[1]))
 for i in range(len(points)-1):a=i*2;faces.append((a,a+1,a+3,a+2))
 return add_mesh(name,verts,faces,black)
for r in eyes:
 cx,cz=r['cx'],r['cz']
 if pose=='neutral':
  disk('Eye '+r['name'],cx,cz,.082,.091,black)
  disk('Highlight '+r['name'],cx+.020,cz+.036,.022,.025,white,.0047)
 else:
  points=[(cx+t*.058,cz+.005+.029*(1-t*t)) for t in np.linspace(-1,1,65)]
  stroke('Smile '+r['name'],points,.012)
if variant=='eyes-mouth':
 disk('Nose',0,.526,.021,.011,black)
 stroke('Nose stem',[(0,z) for z in np.linspace(.519,.492,20)],.006)
 for sign in [-1,1]:
  points=[]
  for t in np.linspace(0,1,50):
   x=sign*.066*t;z=.494-.023*math.sin(math.pi*t*.93);points.append((x,z))
  stroke('Mouth '+str(sign),points,.007)
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(out/'continuous-blink.vrm'));assert result=={'FINISHED'}
new=np.array([v.co for v in mesh.vertices]);assert np.array_equal(new[:,[0,2]],positions[:,[0,2]])
report={'sourceSha256':expected,'variant':variant,'pose':pose,'scope':'static form study; no expression binds; not accepted','verticesWithDepthChange':int(np.count_nonzero(abs(new[:,1]-positions[:,1])>1e-7)),'maxDepthChange':float(abs(new[:,1]-positions[:,1]).max()),'xzUnchanged':True,'surface':{'rx':.445,'rz':.34,'ry':.31,'cy':.04,'cz':.635},'regions':[{**r,'rgb':r['rgb'].tolist()} for r in regions],'outputSha256':hashlib.sha256((out/'continuous-blink.vrm').read_bytes()).hexdigest()}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
