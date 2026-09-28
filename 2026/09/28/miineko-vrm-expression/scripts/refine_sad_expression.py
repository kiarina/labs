"""Move the curved sad expression to relaxed, and make sadness more linear."""
import bpy,copy,hashlib,json,math,os,struct
from pathlib import Path
root=Path(__file__).resolve().parents[1];source=root/'artifacts/eye-emotions';suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ['', '-repeat']
steeper=os.environ.get('SAD_STEEPER')=='1';tilt=.32 if steeper else .28
out=root/'artifacts'/(('eye-emotions-steeper' if steeper else 'eye-emotions-straight')+suffix);out.mkdir(exist_ok=True)
raw=(source/'continuous-blink.vrm').read_bytes();source_hash=hashlib.sha256(raw).hexdigest();assert source_hash==json.loads((source/'report.json').read_text())['outputSha256']
settings=json.loads((root/'artifacts/sync-smile/report.json').read_text());n=struct.unpack_from('<I',raw,12)[0];original=json.loads(raw[20:20+n]);doc=copy.deepcopy(original);tail=raw[20+n:];presets_json=doc['extensions']['VRMC_vrm']['expressions']['preset']
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'));presets=bpy.data.objects['Miineko_Rig'].data.vrm_addon_extension.vrm1.expressions.preset
presets_json['relaxed']=copy.deepcopy(presets_json['sad'])
base_rise=.004;rise=.008;u_scale=math.sqrt(rise/base_rise);rx=.104;sides={};sad=copy.deepcopy(presets_json['happy'])
for bind in sad['textureTransformBinds']:
 material=doc['materials'][bind['material']]['name']
 if material.endswith('upper ink'):continue
 side='L' if ' L ' in material else 'R';label='upper' if material.endswith('upper') else 'lower';c=settings['closureCalibration'][side];slope=(-1 if side=='L' else 1)*tilt
 q=-slope*rx/(2*base_rise*u_scale);compensation=base_rise*q*q;depth=c[label+'Travel']+(-compensation if label=='upper' else compensation)
 bind['scale']=[u_scale,1];bind['offset']=[(1-u_scale)/2+q/16,-c['revealScales'][label]*depth];sides[side]={'slope':slope,'rise':rise,'qOffset':q,'centerCompensation':compensation}
presets_json['sad']=sad
for name in ['relaxed','sad']:
 e=getattr(presets,name)
 for binds in [e.morph_target_binds,e.texture_transform_binds,e.material_color_binds]:binds.clear()
 e.is_binary=False;e.override_blink='none';e.override_mouth='none';e.override_look_at='none'
 for b in presets_json[name]['textureTransformBinds']:
  bind=e.texture_transform_binds.add();bind.material=bpy.data.materials[doc['materials'][b['material']]['name']];bind.scale=b['scale'];bind.offset=b['offset']
for name,value in original['extensions']['VRMC_vrm']['expressions']['preset'].items():
 if name not in ['sad','relaxed']:assert presets_json[name]==value
assert presets_json['relaxed']==original['extensions']['VRMC_vrm']['expressions']['preset']['sad']
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4);target=struct.pack('<4sII',b'glTF',2,20+len(encoded)+len(tail))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+tail
(out/'continuous-blink.vrm').write_bytes(target);bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
report={'sourceSha256':source_hash,'outputSha256':hashlib.sha256(target).hexdigest(),'binaryDataUnchanged':True,'angryAndHappyUnchanged':True,'relaxedEqualsPreviousSad':True,'sad':sides,'tiltMagnitude':tilt,'scope':'sad curvature reduced from .024 to .008; preceding curved sad reassigned exactly to relaxed; no geometry or image changes'}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
