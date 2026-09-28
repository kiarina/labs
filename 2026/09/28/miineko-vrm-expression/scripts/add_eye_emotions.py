"""Add tilted angry/sad eye bands to the accepted smile, preserving its GLB data."""
import bpy,copy,hashlib,json,math,os,struct
from pathlib import Path
root=Path(__file__).resolve().parents[1];source=root/'artifacts/sync-smile';suffix=os.environ.get('STUDY_SUFFIX','');assert suffix in ['', '-repeat']
out=root/'artifacts'/('eye-emotions'+suffix);out.mkdir(exist_ok=True)
raw=(source/'continuous-blink.vrm').read_bytes();source_hash=hashlib.sha256(raw).hexdigest();settings=json.loads((source/'report.json').read_text());assert source_hash==settings['outputSha256']
n=struct.unpack_from('<I',raw,12)[0];original=json.loads(raw[20:20+n]);doc=copy.deepcopy(original);tail=raw[20+n:];expressions=doc['extensions']['VRMC_vrm']['expressions']['preset']
bpy.ops.wm.open_mainfile(filepath=str(source/'continuous-blink.blend'));presets=bpy.data.objects['Miineko_Rig'].data.vrm_addon_extension.vrm1.expressions.preset
report={'sourceSha256':source_hash,'binaryDataUnchanged':True,'otherExpressionsUnchanged':True,'scope':'two tilted eye-band candidates; same head, smile, highlight and mouth; no new facial geometry','expressions':{}}
base_rise=.004;rise=.024;u_scale=math.sqrt(rise/base_rise);rx=.104
for name,direction in [('angry',1),('sad',-1)]:
 old_expression=expressions.get(name,{})
 assert not any(old_expression.get(key) for key in ['morphTargetBinds','textureTransformBinds','materialColorBinds'])
 e=getattr(presets,name)
 for binds in [e.morph_target_binds,e.texture_transform_binds,e.material_color_binds]:binds.clear()
 e.is_binary=False;e.override_blink='none';e.override_mouth='none';e.override_look_at='none'
 result={'isBinary':False,'overrideBlink':'none','overrideMouth':'none','overrideLookAt':'none','textureTransformBinds':[]};sides={}
 for old in expressions['happy']['textureTransformBinds']:
  b=copy.deepcopy(old);material=doc['materials'][b['material']]['name'];side='L' if ' L ' in material else 'R';c=settings['closureCalibration'][side]
  if not material.endswith('upper ink'):
   label='upper' if material.endswith('upper') else 'lower'
   slope=direction*(1 if side=='L' else -1)*.28
   q_offset=-slope*rx/(2*base_rise*u_scale);center_compensation=base_rise*q_offset*q_offset
   depth=c[label+'Travel']+(-center_compensation if label=='upper' else center_compensation)
   b['scale']=[u_scale,1];b['offset']=[(1-u_scale)/2+q_offset/16,-c['revealScales'][label]*depth]
   sides[side]={'slope':slope,'rise':rise,'qOffset':q_offset,'centerCompensation':center_compensation}
  # The old zero-offset ink bind stays inactive, avoiding a second eyebrow.
  result['textureTransformBinds'].append(b)
  bind=e.texture_transform_binds.add();bind.material=bpy.data.materials[material];bind.scale=b['scale'];bind.offset=b['offset']
 expressions[name]=result;report['expressions'][name]=sides
for name in original['extensions']['VRMC_vrm']['expressions']['preset']:
 if name not in ['angry','sad']:assert expressions[name]==original['extensions']['VRMC_vrm']['expressions']['preset'][name]
encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4);target=struct.pack('<4sII',b'glTF',2,20+len(encoded)+len(tail))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+tail
(out/'continuous-blink.vrm').write_bytes(target);bpy.ops.wm.save_as_mainfile(filepath=str(out/'continuous-blink.blend'))
report['outputSha256']=hashlib.sha256(target).hexdigest();(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
