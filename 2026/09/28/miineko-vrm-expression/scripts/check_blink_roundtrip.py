"""Check imported blink bindings; this does not certify round-trip shading."""
import json
import os
from pathlib import Path

import bpy

root=Path(__file__).resolve().parents[1]
folder=root/'artifacts'/os.environ.get('BLINK_RUN','continuous-fresh')
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
result=bpy.ops.import_scene.vrm(filepath=str(folder/'continuous-blink.vrm'))
assert result=={'FINISHED'}
arms=[o for o in bpy.data.objects if o.type=='ARMATURE']
assert len(arms)==1
preset=arms[0].data.vrm_addon_extension.vrm1.expressions.preset
report={'blender':bpy.app.version_string,'scope':'binding import only, shading not certified','expressions':{}}
names=['blink','blink_left','blink_right']
if os.environ.get('VERIFY_RELAXED')=='1':
    names.append('relaxed')
    assert preset.relaxed.override_blink=='blend'
if os.environ.get('VERIFY_HAPPY')=='1':
    names.append('happy')
    assert preset.happy.override_blink=='blend' and preset.happy.override_mouth=='none'
    assert len(preset.happy.morph_target_binds)==6 and len(preset.happy.texture_transform_binds)==4
if os.environ.get('VERIFY_MOUTH')=='1':names.append('aa')
if os.environ.get('VERIFY_VOWELS')=='1':names.extend(['ih','ou','ee','oh'])
for name in names:
    expr=getattr(preset,name)
    morphs=[{'object':b.node.mesh_object_name,'key':b.index,'weight':b.weight} for b in expr.morph_target_binds]
    textures=[{'material':b.material.name,'offset':list(b.offset),'scale':list(b.scale)} for b in expr.texture_transform_binds]
    assert morphs or textures
    for bind in morphs:
        obj=bpy.data.objects[bind['object']]
        assert obj.data.shape_keys and bind['key'] in obj.data.shape_keys.key_blocks
    report['expressions'][name]={'morphs':morphs,'textures':textures,'binary':expr.is_binary}
assert not any(x['binary'] for x in report['expressions'].values())
(folder/'blender-import-report.json').write_text(json.dumps(report,indent=2)+'\n')
print('ROUNDTRIP',json.dumps(report))
