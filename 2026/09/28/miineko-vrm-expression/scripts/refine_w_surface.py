"""Subdivide the W boundary on its existing surface, then recess only black ink.

The pink surface and nose/stem stay pinned. Input is the verified eyes-only
candidate, so the earlier ineffective W deformation is not accumulated.
"""
import bpy, bmesh, numpy as np, os, json, hashlib
from collections import deque
from pathlib import Path
from mathutils.bvhtree import BVHTree
from mathutils import Vector
root=Path(__file__).resolve().parents[1];source=root/'artifacts/feature-eyes';suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ['', '-repeat']
out=root/'artifacts'/('feature-w-surface'+suffix);out.mkdir(exist_ok=True)
expected='068d4aca5ce4a0e9328beb5533c28dbb03bf578fb91e1cb2ff23d9cdd4a29789';assert hashlib.sha256((source/'continuous-blink.vrm').read_bytes()).hexdigest()==expected
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'))
body=bpy.data.objects['Miineko_Body'];mesh=body.data;mesh.calc_loop_triangles()
original_uv=np.array([l.uv for l in mesh.uv_layers[0].data]);original_tri_loops=np.array([list(t.loops) for t in mesh.loop_triangles]);
original=np.array([v.co for v in mesh.vertices]);original_normals=np.array([n.vector for n in mesh.corner_normals])
tri_indices=np.array([list(t.vertices) for t in mesh.loop_triangles]);parent_faces=np.array([t.polygon_index for t in mesh.loop_triangles])
source_tree=BVHTree.FromPolygons([Vector(p) for p in original],tri_indices.tolist(),all_triangles=True)
# Make source triangulation explicit before subdivision. Splitting each quad on
# its existing tessellation diagonal preserves its piecewise-planar surface.
bm=bmesh.new();bm.from_mesh(mesh);bm.verts.ensure_lookup_table();bm.faces.ensure_lookup_table()
normal_layer=bm.loops.layers.float_vector.new('SourceCornerNormal')
for f in bm.faces:
 for loop,normal in zip(f.loops,original_normals[list(mesh.polygons[f.index].loop_indices)]):loop[normal_layer]=normal
for f in list(bm.faces):
 if len(f.verts)==3:continue
 assert len(f.verts)==4,'Unexpected source polygon'
 ts=tri_indices[parent_faces==f.index];assert len(ts)==2
 diagonal=set(ts[0])&set(ts[1]);assert len(diagonal)==2
 a,b=sorted(diagonal);bmesh.utils.face_split(f,bm.verts[a],bm.verts[b])
selected=[]
for edge in bm.edges:
 if any(v.co.y<-.1 and abs(v.co.x)<.112 and .407<v.co.z<.509 for v in edge.verts):selected.append(edge)
bmesh.ops.subdivide_edges(bm,edges=selected,cuts=5,use_grid_fill=True,smooth=0)
bm.to_mesh(mesh);bm.free();mesh.update();mesh.calc_loop_triangles()
before=np.array([v.co for v in mesh.vertices]);tri=np.array([list(t.vertices) for t in mesh.loop_triangles]);loops=np.array([list(t.loops) for t in mesh.loop_triangles]);uv=np.array([l.uv for l in mesh.uv_layers[0].data])
saved_normals=np.array([d.vector for d in mesh.attributes['SourceCornerNormal'].data])
# Subdivision adds points on source triangles; it is not smoothing the head.
distances=np.array([source_tree.find_nearest(Vector(p))[3] for p in before]);assert distances.max()<2e-7,distances.max()
img=next(n.image for n in mesh.materials[0].node_tree.nodes if n.type=='TEX_IMAGE' and n.image and 'BaseColor' in n.image.filepath)
w,h=img.size;px=np.empty(w*h*4,np.float32);img.pixels.foreach_get(px);px=px.reshape(h,w,4)
R,G,B=px[:,:,0],px[:,:,1],px[:,:,2];pink=(R>np.maximum(.08,1.6*G))&(B>np.maximum(.035,1.2*G));pad=np.pad(pink,1,mode='edge');safe=np.logical_or.reduce([pad[j:j+h,i:i+w] for j in range(3) for i in range(3)])
x,y,z=before.T
roi=(y<-.1)&(abs(x)<.103)&(abs(x)>.013)&(z>.412)&(z<.492)
nose_stem=(y<-.1)&(((abs(x)<.045)&(z>=.492)&(z<.575))|((abs(x)<=.013)&(z>.46)&(z<.575)))
protected=~roi|nose_stem
pink_tri=[]
for ti,(ids,ls) in enumerate(zip(tri,loops)):
 if not roi[ids].any():continue
 st=uv[ls]*[w,h];lo=np.maximum(0,np.floor(st.min(0)-1).astype(int));hi=np.minimum([w-1,h-1],np.ceil(st.max(0)+1).astype(int));x0,y0=lo;x1,y1=hi
 xx,yy=np.meshgrid(np.arange(x0,x1+1)+.5,np.arange(y0,y1+1)+.5);d=np.stack([xx,yy],-1)-st[0];a,b=st[1]-st[0],st[2]-st[0];den=a[0]*b[1]-a[1]*b[0]
 if abs(den)<1e-12:hit=safe[y0:y1+1,x0:x1+1].any()
 else:
  s=(d[:,:,0]*b[1]-b[0]*d[:,:,1])/den;t=(a[0]*d[:,:,1]-d[:,:,0]*a[1])/den;inside=(s>=-1e-5)&(t>=-1e-5)&(s+t<=1+1e-5)
  hit=(inside&safe[y0:y1+1,x0:x1+1]).any() if inside.any() else safe[y0:y1+1,x0:x1+1].any()
 if hit:protected[ids]=True;pink_tri.append(ti)
# Keep the same measured local skin target as the preceding experiment.
coeff=np.array([-0.2737511098384857,1.089145129640201e-7,-0.020793752744793892,0.016509154811501503,3.180652129231021e-6,0.018648643046617508])
u=x/.11;v=(z-.463)/.055;target=np.stack([np.ones_like(x),u,v,u*u,u*v,v*v],1)@coeff-.0008
allowed=~protected;ids=np.flatnonzero(allowed);after=before.copy()
# The finer triangles isolate the colored boundary; no broad harmonic clamp
# keeps the entire black ridge at its old height.
adj=[set() for _ in before]
for edge in mesh.edges:
 a,b=edge.vertices;adj[a].add(b);adj[b].add(a)
distance=np.full(len(before),999,int);distance[protected]=0;queue=deque(np.flatnonzero(protected).tolist())
while queue:
 a=queue.popleft()
 for b in adj[a]:
  if distance[b]>distance[a]+1:distance[b]=distance[a]+1;queue.append(b)
weight=np.minimum(1,distance[ids]/3);weight=weight*weight*(3-2*weight)
after[ids,1]+=np.maximum(0,target[ids]-y[ids])*weight
for vertex,p in zip(mesh.vertices,after):vertex.co=p
mesh.update();normals=np.array([n.vector for n in mesh.corner_normals]);changed=np.any(before!=after,axis=1)
for loop in mesh.loops:
 if not changed[loop.vertex_index]:normals[loop.index]=saved_normals[loop.index]
mesh.normals_split_custom_set(normals.tolist())
# This candidate deliberately retains the original materials. A local skin
# repair plus replacement stroke was rejected for visible rings and profile marks.
mesh.attributes.remove(mesh.attributes['SourceCornerNormal'])
assert np.array_equal(before[protected],after[protected]);assert np.array_equal(before[nose_stem],after[nose_stem]);assert np.array_equal(before[:,[0,2]],after[:,[0,2]])
assert all(np.array_equal(before[tri[i]],after[tri[i]]) for i in pink_tri)
np.savez_compressed(out/'audit.npz',before=before,after=after,protected=protected,noseStem=nose_stem,pinkTriangles=tri[pink_tri],sourceSurfaceDistance=distances)
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'));result=bpy.ops.export_scene.vrm(filepath=str(out/'continuous-blink.vrm'));assert result=={'FINISHED'}
delta=after[:,1]-before[:,1]
report={'sourceSha256':expected,'scope':'normal face; refined W topology; pink/nose pinned','vertices':len(before),'originalVertices':len(original),'changedWVertices':int(changed.sum()),'maximumRetraction':float(delta.max()),'medianRetraction':float(np.median(delta[delta>1e-7])),'subdivisionSurfaceMaxDistance':float(distances.max()),'protectedCoordinatesExact':True,'noseStemCoordinatesExact':True,'pinkProtectedTriangles':len(pink_tri),'targetCoefficients':coeff.tolist(),'outputSha256':hashlib.sha256((out/'continuous-blink.vrm').read_bytes()).hexdigest()}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
