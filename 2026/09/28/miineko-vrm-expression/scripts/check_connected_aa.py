"""Check static-surface clearance and reimported AA binding independently."""
import bpy,numpy as np,json,sys,struct
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'scripts'))
from source_ink import SourceInk
folder=root/'artifacts/mouth-connected-aa';settings=json.loads((folder/'report.json').read_text())
# Independently check the recorded source-triangle relationship in double
# precision. Near-vertical source edges make Y-ray differences ill-conditioned;
# the actual parent-plane/nearest-surface distance is the appropriate bound.
a=np.load(folder/'surface-audit.npz');source=a['source'].astype(float);opening=a['opening'].astype(float);tri=a['openingTriangles'];parent=source[a['sourceTriangles'][a['parentTriangle']]]
raw=opening[tri]-a['offset'];normal=np.cross(parent[:,1]-parent[:,0],parent[:,2]-parent[:,0]);length=np.linalg.norm(normal,axis=1);unit=normal/length[:,None]
plane_error=np.abs(np.einsum('tvc,tc->tv',raw-parent[:,None,0],unit));assert plane_error.max()<2e-7,float(plane_error.max())
tree=BVHTree.FromPolygons([Vector(p) for p in source],a['sourceTriangles'].tolist(),all_triangles=True)
nearest=[tree.find_nearest(Vector(p))[3] for p in opening];assert max(nearest)<.000701,max(nearest)
report={'scope':'vertices projected back onto their owning source triangle plane; nearest Euclidean source-surface distance, not Y-ray clearance','parentPlaneMaxError':float(plane_error.max()),'maximumNearestSurfaceDistance':max(nearest),'vertices':len(opening),'triangles':len(tri),'fixedDepthOffset':a['offset'].tolist()}
raw=(folder/'continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0];doc=json.loads(raw[20:20+n]);blob=raw[28+n:]
gm=next(m for m in doc['meshes'] if m['name']=='Connected AA surface');primitive=gm['primitives'][0];accessor=doc['accessors'][primitive['attributes']['COLOR_0']];view=doc['bufferViews'][accessor['bufferView']]
assert accessor['type']=='VEC4' and accessor['componentType']==5123 and accessor['normalized']
color=np.frombuffer(blob,dtype='<u2',count=accessor['count']*4,offset=view.get('byteOffset',0)+accessor.get('byteOffset',0)).reshape(-1,4);assert color[:,3].min()==0 and color[:,3].max()==65535
material=doc['materials'][primitive['material']];assert material['alphaMode']=='BLEND' and 'KHR_materials_unlit' in material['extensions']
texture=doc['textures'][material['pbrMetallicRoughness']['baseColorTexture']['index']];assert doc['samplers'][texture['sampler']]['minFilter']==9729
report['exportedInkMask']={'semantic':'COLOR_0','alphaZeroVertices':int((color[:,3]==0).sum()),'nonMipmapLinear':True,'standardUnlit':True}
# Do not keep mesh RNA handles for later inspection after importer mutations.
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
assert bpy.ops.import_scene.vrm(filepath=str(folder/'continuous-blink.vrm'))=={'FINISHED'}
arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');presets=arm.data.vrm_addon_extension.vrm1.expressions.preset;e=presets.aa
assert len(e.texture_transform_binds)==1 and len(e.morph_target_binds)==0 and not e.is_binary
bind=e.texture_transform_binds[0];assert bind.material is not None and abs(bind.offset[1]+settings['shift'])<1e-6
assert all(len(getattr(presets,name).morph_target_binds)==0 and len(getattr(presets,name).texture_transform_binds)==0 for name in ['ih','ou','ee','oh','blink','relaxed'])
report['reimport']={'aaTextureBinds':1,'aaMorphBinds':0,'offset':list(bind.offset),'material':bind.material.name,'otherVowelsAndEyesNotRestored':True}
(root/'results/connected-aa-geometry.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
