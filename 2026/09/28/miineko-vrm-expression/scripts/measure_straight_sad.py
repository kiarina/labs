"""Check opposite eye-band tilt in frontal angry/sad endpoints."""
import json
from collections import deque
from pathlib import Path
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/straight-sad-review';report={'scope':'central raster curvature and slope; straighter sad compared with remapped relaxed, not subjective emotion recognition','eyes':[]}
def largest(mask):
 seen=np.zeros_like(mask);groups=[]
 for y,x in np.argwhere(mask):
  if seen[y,x]:continue
  q=deque([(y,x)]);seen[y,x]=True;points=[]
  while q:
   j,i=q.popleft();points.append((j,i))
   for dj in [-1,0,1]:
    for di in [-1,0,1]:
     yy,xx=j+dj,i+di
     if 0<=yy<len(mask) and 0<=xx<mask.shape[1] and mask[yy,xx] and not seen[yy,xx]:seen[yy,xx]=True;q.append((yy,xx))
  groups.append(np.array(points))
 return max(groups,key=len)
for emotion,direction in [('relaxed',-1),('sad',-1)]:
 image=np.array(Image.open(folder/f'{emotion}-1-0-0.png').convert('RGB')).astype(int);h,w=image.shape[:2];scale=h/.82
 for side,cx,sign in [('L',.1764,1),('R',-.1848,-1)]:
  x0=int(w/2-(cx+.10)*scale);x1=int(w/2-(cx-.10)*scale);y0=int((1.05-.72)*scale);y1=int((1.05-.49)*scale);crop=image[y0:y1,x0:x1];points=largest(crop.max(2)<70)
  xs=np.unique(points[:,1]);lo,hi=np.quantile(xs,[.2,.8]);xs=xs[(xs>=lo)&(xs<=hi)];centers=np.array([np.median(points[points[:,1]==x,0]) for x in xs]);slope=float(np.polyfit(xs,centers,1)[0]);fit=np.polyfit(xs-xs.mean(),centers,2);rise=float(fit[0]*scale*.104**2);line=np.polyval(np.polyfit(xs,centers,1),xs);deviation=float(np.max(np.abs(line-centers)));assert .12<slope*direction*sign<.5,(emotion,side,slope)
  assert len(points)>500
  white=(crop.min(2)>180)&((crop.max(2)-crop.min(2))<45);assert int(white.sum())==0
  report['eyes'].append({'emotion':emotion,'side':side,'slopeScreenYPerX':slope,'estimatedRise':rise,'maxLineDeviationPixels':deviation,'darkBandPixels':len(points),'brightWhitePixels':int(white.sum()),'innerCorner':'lower' if emotion=='angry' else 'higher'})

for side in ['L','R']:
 old=next(e for e in report['eyes'] if e['emotion']=='relaxed' and e['side']==side);new=next(e for e in report['eyes'] if e['emotion']=='sad' and e['side']==side)
 assert abs(new['estimatedRise'])<abs(old['estimatedRise'])*.6
 assert new['maxLineDeviationPixels']<old['maxLineDeviationPixels']*.75
(root/'results/straight-sad-shape.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
