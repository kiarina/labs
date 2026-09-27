"""Add a composable relaxed-eye expression to a preserved overlay candidate.

Maximum relaxation closes the eyes. Use intermediate weights (e.g. 0.35) for
partially lowered lids. VRM overrideBlink=blend leaves room for automatic blink:
closure = relaxed + (1-relaxed)*blink. No custom runtime mixing is required.
"""
import hashlib
import json
import os
from pathlib import Path

import bpy

root=Path(__file__).resolve().parents[1]
source=root/'artifacts'/os.environ.get('BLINK_INPUT','continuous-fresh')
out=root/'artifacts'/os.environ.get('BLINK_RUN','overlay-selected-plus')
if out.resolve()==source.resolve():
    raise ValueError('Keep the owner-selected baseline unchanged')
out.mkdir(exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'))
arm=next(o for o in bpy.data.objects if o.type=='ARMATURE')
preset=arm.data.vrm_addon_extension.vrm1.expressions.preset
blink=preset.blink
relaxed=preset.relaxed
relaxed.morph_target_binds.clear()
relaxed.texture_transform_binds.clear()
relaxed.material_color_binds.clear()
for original in blink.morph_target_binds:
    bind=relaxed.morph_target_binds.add()
    bind.node.mesh_object_name=original.node.mesh_object_name
    bind.index=original.index
    bind.weight=original.weight
for original in blink.texture_transform_binds:
    bind=relaxed.texture_transform_binds.add()
    bind.material=original.material
    bind.scale=original.scale
    bind.offset=original.offset
relaxed.is_binary=False
relaxed.override_blink='blend'
relaxed.override_mouth='none'
relaxed.override_look_at='none'
assert len(relaxed.texture_transform_binds)==4
assert len(relaxed.morph_target_binds)==2
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(out/'continuous-blink.vrm'))
report={
    'method':'selected-overlay-with-relaxed',
    'source':source.name,
    'sourceVrmSha256':hashlib.sha256((source/'continuous-blink.vrm').read_bytes()).hexdigest(),
    'sourceBlendSha256':hashlib.sha256((source/'continuous-blink.blend').read_bytes()).hexdigest(),
    'blender':bpy.app.version_string,
    'relaxed':{'morphBinds':2,'textureBinds':4,'overrideBlink':'blend','suggestedPartialWeight':.35},
    'export':sorted(result),
}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
