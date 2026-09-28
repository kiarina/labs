"""Check fixed lid geometry and standard expression bindings after VRM import."""
import bpy,numpy as np,json,struct,hashlib
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/surface-expressions';source=root/'artifacts/mouth-connected-vowels';report={'lids':{}}
for path in sorted(folder.glob('audit-*.npz')):
 a=np.load(path);positions=a['source'].astype(float);opening=a['opening'].astype(float);parent=positions[a['sourceTriangles'][a['parentTriangle']]];tri=a['openingTriangles'];raw=opening[tri]-a['offset'];norm=np.cross(parent[:,1]-parent[:,0],parent[:,2]-parent[:,0]);norm/=np.linalg.norm(norm,axis=1)[:,None];error=np.abs(np.einsum('tvc,tc->tv',raw-parent[:,None,0],norm));assert error.max()<2e-7
 tree=BVHTree.FromPolygons([Vector(p) for p in positions],a['sourceTriangles'].tolist(),all_triangles=True);maximum=max(tree.find_nearest(Vector(p))[3] for p in opening);assert maximum<abs(a['offset'][1])+2e-7
 report['lids'][path.stem]={'vertices':len(opening),'triangles':len(tri),'maximumParentPlaneError':float(error.max()),'maximumDistance':maximum}
def doc(path):
 raw=path.read_bytes();n=struct.unpack_from('<I',raw,12)[0];return json.loads(raw[20:20+n])
d=doc(folder/'continuous-blink.vrm');control=doc(root/'artifacts/surface-expressions-source/continuous-blink.vrm');s=doc(source/'continuous-blink.vrm')
# Bindings reference materials by index; compare the five mouth binds semantically.
def mouth(document):
 result={}
 for name in ['aa','ih','ou','ee','oh']:
  expr=document['extensions']['VRMC_vrm']['expressions']['preset'][name];binds=[]
  for bind in expr['textureTransformBinds']:binds.append({**bind,'material':document['materials'][bind['material']]['name']})
  result[name]=binds
 return result
assert mouth(d)==mouth(s)==mouth(control);report['mouthBindingsUnchanged']=True
for variant in ['surface-expressions','surface-expressions-source']:
 a=root/'artifacts'/variant
 bpy.ops.wm.open_mainfile(filepath=str(a/'continuous-blink.blend'));body=bpy.data.objects['Miineko_Body'];coords=np.array([v.co for v in body.data.vertices]);assert np.array_equal(coords,positions)
 for obj in bpy.data.objects:
  if obj.name.startswith('Surface Lid'):
   assert not obj.data.shape_keys;obj.data.calc_loop_triangles();assert np.isfinite(np.array([n.vector for n in obj.data.corner_normals])).all()
report['sourceBodyCoordinatesExact']=True;report['noLidMorphs']=True
bpy.ops.object.select_all(action="SELECT");bpy.ops.object.delete(use_global=False);assert bpy.ops.import_scene.vrm(filepath=str(folder/'continuous-blink.vrm'))=={'FINISHED'}
arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');presets=arm.data.vrm_addon_extension.vrm1.expressions.preset;bindings={}
for name,count in [('happy',4),('relaxed',4),('blink',4),('blink_left',2),('blink_right',2)]:
 e=getattr(presets,name);assert len(e.texture_transform_binds)==count and not e.morph_target_binds and not e.is_binary and e.override_blink=='none';assert all(b.material for b in e.texture_transform_binds);bindings[name]=count
report['reimportTextureBinds']=bindings;report['scope']='fixed source-following lids, unchanged head and vowel bindings; no all-pose or aesthetic guarantee'
(root/'results/surface-expressions-geometry.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
