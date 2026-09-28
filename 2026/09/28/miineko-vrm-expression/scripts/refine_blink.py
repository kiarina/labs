"""Align ordinary closure with the accepted shared-onset, upper-led eye method."""
import bpy,copy,hashlib,json,math,os,struct
from pathlib import Path
root=Path(__file__).resolve().parents[1];source=root/'artifacts/surprise-ears';suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ('','-repeat')
out=root/'artifacts'/('blink-aligned'+suffix);out.mkdir(exist_ok=True)
raw=(source/'continuous-blink.vrm').read_bytes();assert hashlib.sha256(raw).hexdigest()==json.loads((source/'report.json').read_text())['outputSha256']
n=struct.unpack_from('<I',raw,12)[0];original=json.loads(raw[20:20+n]);doc=copy.deepcopy(original);tail=raw[20+n:];preset=doc['extensions']['VRMC_vrm']['expressions']['preset']
scale=math.sqrt(.008/.004)
for name,side in [('blink',None),('blinkLeft','L'),('blinkRight','R')]:
 e=copy.deepcopy(preset['happy']);binds=[]
 for b in e['textureTransformBinds']:
  material=doc['materials'][b['material']]['name']
  if side and f' {side} ' not in material:continue
  if not material.endswith('upper ink'):b['scale']=[scale,1];b['offset'][0]=(1-scale)/2
  binds.append(b)
 e['textureTransformBinds']=binds;preset[name]=e
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'));presets=bpy.data.objects['Miineko_Rig'].data.vrm_addon_extension.vrm1.expressions.preset
for name,key in [('blink','blink'),('blinkLeft','blink_left'),('blinkRight','blink_right')]:
 e=getattr(presets,key)
 for binds in [e.morph_target_binds,e.texture_transform_binds,e.material_color_binds]:binds.clear()
 for b in preset[name]['textureTransformBinds']:
  bind=e.texture_transform_binds.add();bind.material=bpy.data.materials[doc['materials'][b['material']]['name']];bind.scale=b['scale'];bind.offset=b['offset']
 e.is_binary=False;e.override_blink='none';e.override_mouth='none';e.override_look_at='none'
restored=copy.deepcopy(doc)
for name in ['blink','blinkLeft','blinkRight']:restored['extensions']['VRMC_vrm']['expressions']['preset'][name]=original['extensions']['VRMC_vrm']['expressions']['preset'][name]
assert restored==original
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4);target=struct.pack('<4sII',b'glTF',2,20+len(encoded)+len(tail))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+tail
(out/'continuous-blink.vrm').write_bytes(target);bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
report={'sourceSha256':hashlib.sha256(raw).hexdigest(),'outputSha256':hashlib.sha256(target).hexdigest(),'onlyBlinkPresetsChanged':True,'binaryChunkIdentical':True,'rise':.008,'centerGap':.024,'closureTravel':'same as accepted happy, approximately upper 70%, lower 30%','highlight':'original artwork, naturally occluded; no color bind','upperInk':'disabled like accepted happy; retain original-eye black band'}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
