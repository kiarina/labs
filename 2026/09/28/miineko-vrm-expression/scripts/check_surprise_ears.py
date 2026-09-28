"""Check retained source data, authoring shape key and imported VRM binding."""
import bpy,copy,json,struct,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[1];source=root/'artifacts/eye-emotions-steeper';folder=root/'artifacts/surprise-ears'
def load(path):
 raw=path.read_bytes();n=struct.unpack_from('<I',raw,12)[0];return json.loads(raw[20:20+n]),raw[28+n:]
base,bb=load(source/'continuous-blink.vrm');new,nb=load(folder/'continuous-blink.vrm');assert nb[:len(bb)]==bb
restored=copy.deepcopy(new)
for name in ['accessors','bufferViews']:restored[name]=restored[name][:len(base[name])]
restored['buffers']=base['buffers'];restored['extensions']['VRMC_vrm']['expressions']['preset']['surprised']=base['extensions']['VRMC_vrm']['expressions']['preset']['surprised']
mi=next(i for i,m in enumerate(base['meshes']) if m['name'].startswith('tripo_mesh'))
for p in restored['meshes'][mi]['primitives']:del p['targets']
del restored['meshes'][mi]['weights'];del restored['meshes'][mi]['extras'];assert restored==base
assert (folder/'continuous-blink.vrm').read_bytes()==(root/'artifacts/surprise-ears-repeat/continuous-blink.vrm').read_bytes()
def inspect():
 arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');e=arm.data.vrm_addon_extension.vrm1.expressions.preset.surprised
 assert len(e.morph_target_binds)==1 and not e.texture_transform_binds and not e.material_color_binds
 b=e.morph_target_binds[0];obj=bpy.data.objects[b.node.mesh_object_name];key=obj.data.shape_keys.key_blocks[b.index];basis=obj.data.shape_keys.key_blocks[0];moved=[(v.co-u.co).length for v,u in zip(key.data,basis.data)];assert max(moved)>.04
 assert key.name=='Surprise Ears Up' and b.weight==1
 return {'key':key.name,'weight':b.weight,'movedVertices':sum(v>1e-7 for v in moved),'maxDisplacement':max(moved)}
bpy.ops.wm.open_mainfile(filepath=str(folder/'continuous-blink.blend'));saved=inspect();bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
assert bpy.ops.import_scene.vrm(filepath=str(folder/'continuous-blink.vrm'))=={'FINISHED'};imported=inspect()
assert abs(saved['maxDisplacement']-imported['maxDisplacement'])<1e-6
report={'originalBinaryPrefixUnchanged':True,'onlyBodyMorphAndSurprisedAdded':True,'repeatByteIdentical':True,'saved':saved,'imported':imported,'scope':'binding and endpoint displacement reimport, not full runtime/pose acceptance','outputSha256':hashlib.sha256((folder/'continuous-blink.vrm').read_bytes()).hexdigest()}
(root/'results/surprise-ears-structure.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
