"""Measure full-smile arc silhouettes and look for detached ink at sampled weights."""
import json
from pathlib import Path
from collections import deque
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/rounded-smile-review'
def components(mask):
 seen=np.zeros_like(mask);groups=[]
 for y,x in np.argwhere(mask):
  if seen[y,x]:continue
  seen[y,x]=True;q=deque([(y,x)]);points=[]
  while q:
   yy,xx=q.popleft();points.append((yy,xx))
   for dy in [-1,0,1]:
    for dx in [-1,0,1]:
     j,i=yy+dy,xx+dx
     if 0<=j<len(mask) and 0<=i<mask.shape[1] and mask[j,i] and not seen[j,i]:seen[j,i]=True;q.append((j,i))
  groups.append(np.array(points))
 return sorted(groups,key=len,reverse=True)
def read(name):return np.array(Image.open(folder/(name+'.png')).convert('RGB'))
report={'scope':'frontal raster arc extent and sampled ink connectivity, not an all-frame aesthetic proof','full':[],'intermediate':[]}
for variant in ['expressions','rounded']:
 image=read(f'{variant}-happy-1-0');h,w=image.shape[:2];scale=h/.82
 for side,cx in [('L',.1764),('R',-.1848)]:
  x0=int(w/2-(cx+.077)*scale);x1=int(w/2-(cx-.077)*scale);y0=int((.64+.41-.678)*scale);y1=int((.64+.41-.595)*scale)
  crop=image[y0:y1,x0:x1];groups=components(crop.max(2)<70);assert groups and len(groups[0])>30
  points=groups[0];lo=points.min(0);hi=points.max(0);width=int(hi[1]-lo[1]+1);height=int(hi[0]-lo[0]+1)
  report['full'].append({'variant':variant,'side':side,'pixels':len(points),'widthPixels':width,'heightPixels':height,'heightWidthRatio':height/width})
for side in ['L','R']:
 before=next(x for x in report['full'] if x['variant']=='expressions' and x['side']==side);after=next(x for x in report['full'] if x['variant']=='rounded' and x['side']==side)
 assert after['heightWidthRatio']>before['heightWidthRatio']*2
 assert after['widthPixels']<before['widthPixels']
for weight in [.25,.5,.75,1]:
 image=read(f'rounded-happy-{weight}-0');h,w=image.shape[:2];scale=h/.82
 for side,cx in [('L',.1764),('R',-.1848)]:
  x0=int(w/2-(cx+.102)*scale);x1=int(w/2-(cx-.102)*scale);y0=int((.64+.41-.770)*scale);y1=int((.64+.41-.490)*scale)
  groups=components(image[y0:y1,x0:x1].max(2)<70);large=[len(p) for p in groups if len(p)>20];assert len(large)==1,(weight,side,large)
  report['intermediate'].append({'weight':weight,'side':side,'significantDarkComponents':len(large),'largestPixels':large[0]})
(root/'results/rounded-smile-silhouette.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
