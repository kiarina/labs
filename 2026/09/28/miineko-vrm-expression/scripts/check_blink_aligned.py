"""Audit expression-only GLB changes and round-trip the new standard presets."""
import bpy,copy,json,struct,hashlib,os
from pathlib import Path
root=Path(__file__).resolve().parents[1];source=root/'artifacts/surprise-ears';folder=root/'artifacts/blink-aligned'
def load(path):
 raw=path.read_bytes();n=struct.unpack_from('<I',raw,12)[0];return json.loads(raw[20:20+n]),raw[20+n:]
base,base_tail=load(source/'continuous-blink.vrm');new,new_tail=load(folder/'continuous-blink.vrm');assert base_tail==new_tail
restored=copy.deepcopy(new);bp=base['extensions']['VRMC_vrm']['expressions']['preset'];np=restored['extensions']['VRMC_vrm']['expressions']['preset']
for name in ['blink','blinkLeft','blinkRight']:
 if name in bp:np[name]=copy.deepcopy(bp[name])
 else:del np[name]
assert restored==base
assert (folder/'continuous-blink.vrm').read_bytes()==(root/'artifacts'/'blink-aligned-repeat'/'continuous-blink.vrm').read_bytes()
# Bind values in the saved authoring scene and imported runtime model must agree.
def inspect():
 arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');presets=arm.data.vrm_addon_extension.vrm1.expressions.preset;result={}
 for name in ['blink','blinkLeft','blinkRight']:
  e=getattr(presets,{'blinkLeft':'blink_left','blinkRight':'blink_right'}.get(name,name));assert not e.is_binary and not e.morph_target_binds and not e.material_color_binds and e.override_blink=='none' and e.override_mouth=='none'
  assert len(e.texture_transform_binds)==(6 if name=='blink' else 3)
  result[name]=sorted([{'material':b.material.name,'scale':list(b.scale),'offset':list(b.offset)} for b in e.texture_transform_binds],key=lambda b:b['material'])
 return result
bpy.ops.wm.open_mainfile(filepath=str(folder/'continuous-blink.blend'));saved=inspect();bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
for material in list(bpy.data.materials):bpy.data.materials.remove(material,do_unlink=True)
assert bpy.ops.import_scene.vrm(filepath=str(folder/'continuous-blink.vrm'))=={'FINISHED'};imported=inspect();assert saved==imported
report={'binaryChunkIdentical':True,'onlyThreeBlinkPresetsChanged':True,'savedAndImportedBindsIdentical':True,'repeatByteIdentical':True,'bindings':imported}
(root/'results/blink-aligned-structure.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
