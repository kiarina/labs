"""Prototype a manga smile on the accepted lids without changing the base face."""
import hashlib
import json
import os
from pathlib import Path
import struct
import bisect
import bpy

root=Path(__file__).resolve().parents[1]
source=root/'artifacts/mouth-aa-aligned'
out=root/'artifacts'/os.environ.get('HAPPY_RUN','happy-arc')
assert out.resolve()!=source.resolve()
out.mkdir(parents=True,exist_ok=True)
expected='cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31'
assert hashlib.sha256((source/'continuous-blink.vrm').read_bytes()).hexdigest()==expected
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'))
arm=next(o for o in bpy.data.objects if o.type=='ARMATURE')
presets=arm.data.vrm_addon_extension.vrm1.expressions.preset
happy=presets.happy
for collection in [happy.morph_target_binds,happy.texture_transform_binds,happy.material_color_binds]:collection.clear()
for original in presets.blink.morph_target_binds:
    bind=happy.morph_target_binds.add();bind.node.mesh_object_name=original.node.mesh_object_name;bind.index=original.index;bind.weight=original.weight
for original in presets.blink.texture_transform_binds:
    bind=happy.texture_transform_binds.add();bind.material=original.material;bind.scale=original.scale;bind.offset=original.offset
height=float(os.environ.get('HAPPY_HEIGHT','.035'))
if not 0<height<=.06:raise ValueError('HAPPY_HEIGHT must be finite and in (0, .06]')
centers={'L':(.1764,.619),'R':(-.1848,.619)}
modified=[]
for side,(cx,cz) in centers.items():
    columns={}
    for label in ['upper','lower']:
        for v in bpy.data.objects[f'Lid {side} {label}'].data.vertices:
            columns.setdefault(round(v.co.x,6),{})[float(v.co.z)]=float(v.co.y)
    columns={x:sorted(points.items()) for x,points in columns.items()}
    for label in ['upper','lower']:
        obj=bpy.data.objects[f'Lid {side} {label}']
        basis=obj.shape_key_add(name='Basis');key=obj.shape_key_add(name='HappyArc')
        for original,target in zip(basis.data,key.data):
            x=(original.co.x-cx)/.102
            local_z=original.co.z-cz-.008*(1-x*x)
            # Keep the shell perimeter fixed, raising only the shared seam.
            arc=max(0,1-x*x)
            center=max(0,1-abs(local_z)/.105)
            target.co.z+=height*arc*center
            points=columns[round(original.co.x,6)];zs=[p[0] for p in points]
            i=max(0,min(len(points)-2,bisect.bisect_right(zs,target.co.z)-1))
            z0,y0=points[i];z1,y1=points[i+1]
            t=max(0,min(1,(target.co.z-z0)/(z1-z0)))
            target.co.y=y0*(1-t)+y1*t
        bind=happy.morph_target_binds.add();bind.node.mesh_object_name=obj.name;bind.index=key.name;bind.weight=1
        modified.append(obj.name)
happy.is_binary=False;happy.override_blink='blend';happy.override_mouth='none';happy.override_look_at='none'
bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
result=bpy.ops.export_scene.vrm(filepath=str(out/'continuous-blink.vrm'));assert result=={'FINISHED'}
path=out/'continuous-blink.vrm';raw=path.read_bytes();length=struct.unpack_from('<I',raw,12)[0]
doc=json.loads(raw[20:20+length]);tail=raw[20+length:]
material=next(m for m in doc['materials'] if m['name']=='Cartoon mouth single palette')
texture=doc['textures'][material['pbrMetallicRoughness']['baseColorTexture']['index']]
sampler=dict(doc['samplers'][texture['sampler']]);sampler.update(minFilter=9729,magFilter=9729)
texture['sampler']=len(doc['samplers']);doc['samplers'].append(sampler)
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
path.write_bytes(struct.pack('<4sII',b'glTF',2,20+len(encoded)+len(tail))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+tail)
report={'sourceSha256':expected,'sourceBlendSha256':hashlib.sha256((source/'continuous-blink.blend').read_bytes()).hexdigest(),'scriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'outputSha256':hashlib.sha256(path.read_bytes()).hexdigest(),'height':height,'modifiedLids':modified,'happyMorphBinds':len(happy.morph_target_binds),'happyTextureBinds':len(happy.texture_transform_binds),'overrideBlink':'blend','overrideMouth':'none','blender':bpy.app.version_string,'scope':'smile eye prototype; owner acceptance pending'}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
