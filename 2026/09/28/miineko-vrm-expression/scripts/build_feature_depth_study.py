"""Recess only safe interior eye/W vertices; pin pink faces, nose and stem.

UV triangle raster classification is conservative: any triangle touching pink
texels protects all its vertices. Original bitmaps and protected normals remain.
"""
import bpy, numpy as np, os, json, hashlib, math
from collections import deque
from pathlib import Path
root=Path(__file__).resolve().parents[1];source=root/'artifacts/mouth-aa-aligned'
expected='cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31'
assert hashlib.sha256((source/'continuous-blink.vrm').read_bytes()).hexdigest()==expected
variant=os.environ.get('FEATURE_STUDY','eyes-mouth');assert variant in ['eyes','eyes-mouth']
suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ['', '-repeat']
out=root/'artifacts'/f'feature-{variant}{suffix}';out.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'))
body=bpy.data.objects['Miineko_Body'];arm=bpy.data.objects['Miineko_Rig'];mesh=body.data
positions=np.array([v.co for v in mesh.vertices]);mesh.calc_loop_triangles();triangles=list(mesh.loop_triangles);triangle_indices=np.array([list(t.vertices) for t in triangles])
original_normals=np.array([n.vector for n in mesh.corner_normals]);uv=np.array([l.uv for l in mesh.uv_layers[0].data])
image=next(n.image for n in mesh.materials[0].node_tree.nodes if n.type=='TEX_IMAGE' and n.image and 'BaseColor' in n.image.filepath)
w,h=image.size;pixels=np.empty(w*h*4,np.float32);image.pixels.foreach_get(pixels);pixels=pixels.reshape(h,w,4)
# Pink is a chromatic classification, including dark pink shading. White eye
# highlights are intentionally included with eyes, never with the skin mask.
r,g,b=pixels[:,:,0],pixels[:,:,1],pixels[:,:,2]
pink=(r>np.maximum(.08,1.6*g))&(b>np.maximum(.035,1.2*g))
# Dilate by one texel to cover filtering and boundary uncertainty conservatively.
padded=np.pad(pink,1,mode='edge');pink_safe=np.logical_or.reduce([padded[j:j+h,i:i+w] for j in range(3) for i in range(3)])
def tri_pink(t):
 st=uv[list(t.loops)]*np.array([w,h]);lo=np.floor(st.min(0)-1).astype(int);hi=np.ceil(st.max(0)+1).astype(int)
 x0,y0=np.maximum(lo,0);x1,y1=np.minimum(hi,np.array([w-1,h-1]))
 xx,yy=np.meshgrid(np.arange(x0,x1+1)+.5,np.arange(y0,y1+1)+.5);pts=np.stack([xx,yy],-1)
 a,bb,c=st;v0,v1=bb-a,c-a;den=v0[0]*v1[1]-v1[0]*v0[1]
 if abs(den)<1e-12:return bool(pink_safe[y0:y1+1,x0:x1+1].any())
 d=pts-a;s=(d[:,:,0]*v1[1]-v1[0]*d[:,:,1])/den;t2=(v0[0]*d[:,:,1]-d[:,:,0]*v0[1])/den
 inside=(s>=-1e-5)&(t2>=-1e-5)&(s+t2<=1+1e-5)
 return bool(np.any(inside&pink_safe[y0:y1+1,x0:x1+1])) if inside.any() else bool(pink_safe[y0:y1+1,x0:x1+1].any())
pink_flags=np.array([tri_pink(t) for t in triangles])
front=positions[:,1]<-.1;x=positions[:,0];z=positions[:,2]
eye_left=front&(((x-.1764)/.104)**2+((z-.619)/.113)**2<1)
eye_right=front&(((x+.1848)/.104)**2+((z-.619)/.113)**2<1)
# Nose and its center stem are protected by region regardless of texel color.
nose_stem=front&(abs(x)<.045)&(z>.472)&(z<.574)
W=front&(abs(x)<.093)&(abs(x)>.013)&(z>.424)&(z<.481)
# Pink-tinted reflections inside an eye are not head skin. Keep only pink
# triangle components connected to the surrounding non-feature surface.
feature_roi=eye_left|eye_right|W
edges={};neighbors=[set() for _ in triangles]
for i,ids in enumerate(triangle_indices):
 for a,b in zip(ids,np.roll(ids,-1)):
  edge=tuple(sorted((int(a),int(b))))
  if edge in edges:neighbors[i].add(edges[edge]);neighbors[edges[edge]].add(i)
  else:edges[edge]=i
seed=[i for i,ids in enumerate(triangle_indices) if pink_flags[i] and not feature_roi[ids].all()]
connected=np.zeros(len(triangles),bool);connected[seed]=True;queue=deque(seed)
while queue:
 i=queue.popleft()
 for j in neighbors[i]:
  if pink_flags[j] and not connected[j]:connected[j]=True;queue.append(j)
pink_triangles=np.flatnonzero(connected).tolist();protected=np.zeros(len(positions),bool)
for i in pink_triangles:protected[triangle_indices[i]]=True
protected|=nose_stem
vertex_pink=np.zeros(len(positions),bool)
for loop in mesh.loops:
 u0,v0=uv[loop.index];vertex_pink[loop.vertex_index]|=pink[min(h-1,max(0,int(v0*h))),min(w-1,max(0,int(u0*w)))]
adj=[set() for _ in positions]
for e in mesh.edges:a,b=e.vertices;adj[a].add(b);adj[b].add(a)
new=positions.copy();regions=[]
for name,roi,cx,cz,rx,rz in [('eye-L',eye_left,.1764,.619,.104,.113),('eye-R',eye_right,-.1848,.619,.104,.113),('w-mouth',W,0,.463,.11,.055)]:
 if name=='w-mouth' and variant=='eyes':continue
 allowed=roi&~protected;ids=np.flatnonzero(allowed)
 # Fit the target only from surrounding chromatic pink vertices, not from the
 # old eye dome, nose or the black mouth ridge.
 u=(x-cx)/rx;v=(z-cz)/rz
 ring=front&vertex_pink&~nose_stem&((u*u+v*v)>.85**2)&((u*u+v*v)<1.6**2)
 if name=='w-mouth':ring&=(z<.493)
 design=np.stack([np.ones_like(x),u,v,u*u,u*v,v*v],axis=1)
 coeff=np.linalg.lstsq(design[ring],positions[ring,1],rcond=None)[0]
 target=design@coeff-.001
 # A smooth Dirichlet surface through the pinned ink boundary limits recession:
 # the new eye must not become a dish behind a still-raised black rim.
 harmonic=positions[:,1].copy();weights={}
 for i in ids:
  ns=np.array(sorted(adj[i]));d=positions[ns][:,[0,2]]-positions[i,[0,2]]
  ws=1/np.maximum(np.linalg.norm(d,axis=1),.001);weights[i]=(ns,ws/ws.sum())
 for _ in range(250):
  old=harmonic.copy()
  for i in ids:
   ns,ws=weights[i];harmonic[i]=old[ns]@ws
  if np.max(abs(harmonic-old))<1e-8:break
 target=np.minimum(target,harmonic-.0005)
 # Distance from protected neighbors tapers the adjustment at the ink edge.
 distance=np.zeros(len(positions),int)
 for i in ids:distance[i]=1 if any(not allowed[j] for j in adj[i]) else 999
 for _ in range(20):
  old=distance.copy()
  for i in ids:distance[i]=min(distance[i],min((old[j]+1 for j in adj[i]),default=999))
  if np.array_equal(distance,old):break
 influence=np.minimum(1,distance[ids]/2);influence=influence*influence*(3-2*influence)
 # Recess only: never inflate any ink vertex beyond its original depth.
 delta=np.maximum(0,target[ids]-positions[ids,1])*influence
 new[ids,1]+=delta
 regions.append({'name':name,'eligibleVertices':len(ids),'changedVertices':int(np.count_nonzero(delta>1e-7)),'maxRetraction':float(delta.max(initial=0)),'fitSamples':int(ring.sum()),'coefficients':coeff.tolist()})
body.shape_key_clear()
for vertex,p in zip(mesh.vertices,new):vertex.co=p
mesh.update();new_normals=np.array([n.vector for n in mesh.corner_normals]);changed=np.any(new!=positions,axis=1)
for loop in mesh.loops:
 if not changed[loop.vertex_index]:new_normals[loop.index]=original_normals[loop.index]
mesh.normals_split_custom_set(new_normals.tolist())
for o in list(bpy.data.objects):
 if o.type=='MESH' and o!=body:bpy.data.objects.remove(o,do_unlink=True)
for name in ['happy','relaxed','blink','blink_left','blink_right','aa','ih','ou','ee','oh']:
 e=getattr(arm.data.vrm_addon_extension.vrm1.expressions.preset,name)
 for binds in [e.morph_target_binds,e.texture_transform_binds,e.material_color_binds]:binds.clear()
 e.override_blink='none';e.override_mouth='none'
assert np.array_equal(new[protected],positions[protected])
assert np.array_equal(new[nose_stem],positions[nose_stem])
assert np.array_equal(new[:,[0,2]],positions[:,[0,2]])
# Every triangle classified as pink retains its three vertex coordinates.
assert all(np.array_equal(new[triangle_indices[i]],positions[triangle_indices[i]]) for i in pink_triangles)
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(out/'continuous-blink.vrm'));assert result=={'FINISHED'}
report={'sourceSha256':expected,'sourceBlendSha256':hashlib.sha256((source/'continuous-blink.blend').read_bytes()).hexdigest(),'variant':variant,'scope':'neutral only; conservative pink UV mask, no skin cover or texture edits','pinkTriangleCount':len(pink_triangles),'isolatedPinkReflectionTriangles':int((pink_flags&~connected).sum()),'protectedVertices':int(protected.sum()),'protectedCoordinatesExact':True,'noseStemVertices':int(nose_stem.sum()),'noseStemCoordinatesExact':True,'xzExact':True,'changedVertices':int(changed.sum()),'regions':regions,'outputSha256':hashlib.sha256((out/'continuous-blink.vrm').read_bytes()).hexdigest()}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');np.savez_compressed(out/'audit.npz',before=positions,after=new,protected=protected,noseStem=nose_stem,pinkTriangles=np.array([triangle_indices[i] for i in pink_triangles]))
print(json.dumps(report))
