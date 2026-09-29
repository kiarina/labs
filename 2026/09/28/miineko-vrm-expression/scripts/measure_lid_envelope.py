"""Inspect unexpected black/white fragments above the intended closed-eye line."""
import json,struct
from pathlib import Path
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/lid-gap-review';raw=(root/'artifacts/lid-rim-clean/continuous-blink.vrm').read_bytes();n=struct.unpack_from('<I',raw,12)[0];d=json.loads(raw[20:20+n]);bb=raw[28+n:];points=[]
for m in d['meshes']:
 for p in m['primitives']:
  if not d['materials'][p['material']]['name'].startswith('Original eye'):continue
  a=d['accessors'][p['attributes']['POSITION']];v=d['bufferViews'][a['bufferView']];xyz=np.frombuffer(bb,dtype='<f4',count=a['count']*3,offset=v.get('byteOffset',0)+a.get('byteOffset',0)).reshape(-1,3);points.append(xyz[(xyz[:,1]>.625)&(xyz[:,1]<.71)])
results=[]
for angle in [0,15,30,45,60,75,90,-15,-30,-45,-60,-75,-90]:
 rad=np.deg2rad(angle)
 for pose in ['reference86','blink','happy','angry','sad','relaxed']:
  counts=[]
  for variant in ['lid-rim-clean','lid-envelope']:
   image=np.array(Image.open(folder/f'{variant}-{pose}-{angle}.png').convert('RGB')).astype(int);h,w=image.shape[:2];scale=h/.82;mask=np.zeros((h,w),bool)
   for pts in points:
    projected=(pts[:,0]*np.cos(rad)-pts[:,2]*np.sin(rad))*scale+w/2
    x0=max(0,int(projected.min())-2);x1=min(w,int(projected.max())+3);y0=int((1.05-.69)*scale);y1=int((1.05-.635)*scale);mask[y0:y1,x0:x1]=True
   bad=((image.max(2)<80)|((image.min(2)>210)&(image.max(2)-image.min(2)<40)))&mask;counts.append(int(bad.sum()))
  results.append({'angle':angle,'pose':pose,'sourceFragments':counts[0],'candidateFragments':counts[1]})
print(json.dumps(results))
assert sum(r['sourceFragments'] for r in results)>100
assert max(r['candidateFragments'] for r in results)==0,[(r) for r in results if r['candidateFragments']>0]
report={'scope':'fixed-camera band y=.635..69 above closed-eye line; projected eye bounds, very dark/white pixel counts; not whole-surface proof','views':results};(root/'results/lid-envelope-fragments.json').write_text(json.dumps(report,indent=2)+'\n')

ink=[]
for pose in ['reference86','blink','happy','angry','sad','relaxed']:
 a=np.array(Image.open(folder/f'lid-rim-clean-{pose}-0.png'));b=np.array(Image.open(folder/f'lid-envelope-{pose}-0.png'));count=int(((a.max(2)<80)!=(b.max(2)<80)).sum());assert count==0;ink.append({'pose':pose,'changedInkPixels':count})
(root/'results/lid-envelope-ink.json').write_text(json.dumps({'scope':'front dark-ink masks only','poses':ink},indent=2)+'\n')
