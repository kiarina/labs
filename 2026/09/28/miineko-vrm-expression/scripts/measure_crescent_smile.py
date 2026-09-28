"""Compare the new endpoint to the owner's former 92% silhouette."""
import json
from pathlib import Path
from collections import deque
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/crescent-smile-review'
def read(name):return np.array(Image.open(folder/(name+'.png')).convert('RGB')).astype(int)
def components(mask):
 seen=np.zeros_like(mask);groups=[]
 for y,x in np.argwhere(mask):
  if seen[y,x]:continue
  seen[y,x]=True;q=deque([(y,x)]);points=[]
  while q:
   j,i=q.popleft();points.append((j,i))
   for dj in [-1,0,1]:
    for di in [-1,0,1]:
     yy,xx=j+dj,i+di
     if 0<=yy<len(mask) and 0<=xx<mask.shape[1] and mask[yy,xx] and not seen[yy,xx]:seen[yy,xx]=True;q.append((yy,xx))
  groups.append(np.array(points))
 return sorted(groups,key=len,reverse=True)
images={n:read(n) for n in ['rounded-happy-0.92-0','rounded-happy-1-0','crescent-happy-1-0']};h,w=next(iter(images.values())).shape[:2];scale=h/.82
report={'scope':'fixed frontal comparison against former 92%; white-highlight removal, width/area, lower-edge agreement; not all-view proof','eyes':[]}
for side,cx in [('L',.1764),('R',-.1848)]:
 x0=int(w/2-(cx+.101)*scale);x1=int(w/2-(cx-.101)*scale);y0=int((.64+.41-.750)*scale);y1=int((.64+.41-.510)*scale);samples={};boundaries={}
 for name,image in images.items():
  crop=image[y0:y1,x0:x1];dark=crop.max(2)<70;white=(crop.min(2)>150)&((crop.max(2)-crop.min(2))<45)
  mask=dark|white if '0.92' in name else dark;groups=components(mask);p=groups[0];lo=p.min(0);hi=p.max(0);edge={int(x):int(p[p[:,1]==x,0].max()) for x in np.unique(p[:,1])};boundaries[name]=edge
  samples[name]={'width':int(hi[1]-lo[1]+1),'height':int(hi[0]-lo[0]+1),'silhouettePixels':len(p),'whitePixels':int(white.sum()),'largeComponents':sum(len(g)>20 for g in groups)}
 old=samples['rounded-happy-0.92-0'];thin=samples['rounded-happy-1-0'];new=samples['crescent-happy-1-0']
 assert old['whitePixels']>20 and new['whitePixels']==0
 assert new['width']>thin['width']*1.3 and new['silhouettePixels']>thin['silhouettePixels']*2
 assert abs(new['width']-old['width'])<=2 and new['largeComponents']==1
 before=boundaries['rounded-happy-0.92-0'];after=boundaries['crescent-happy-1-0'];xs=sorted(set(before)&set(after));errors=np.array([abs(before[x]-after[x]) for x in xs]);inner=errors[len(xs)//20:-len(xs)//20];assert inner.max()<=2 and errors.mean()<.3,(side,float(errors.mean()),int(inner.max()))
 report['eyes'].append({'side':side,'samples':samples,'lowerEdgeMaxPixelError':int(errors.max()),'inner90PercentMaxPixelError':int(inner.max()),'lowerEdgeMeanPixelError':float(errors.mean())})
(root/'results/crescent-smile-silhouette.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
