"""Compare visible lid onset in the same frontal capture, normalized by travel."""
from pathlib import Path
import json
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/sync-smile-review';weights=[0,.02,.04,.06,.08,.1,.13,.16,.2,.5,1]
def read(variant,weight):return np.array(Image.open(folder/f'onset-{variant}-{weight:g}.png').convert('RGB')).astype(int)
base=read('sync',0);h,w=base.shape[:2];scale=h/.82
report={'scope':'central five columns in fixed front view; first movement is >=1 median pixel at sampled strengths, not continuous-time or every-eye-column proof','eyes':[]}
for side,cx in [('L',.1764),('R',-.1848)]:
 x0=int(w/2-(cx+.1)*scale);x1=int(w/2-(cx-.1)*scale);y0=int((1.05-.75)*scale);y1=int((1.05-.51)*scale);center=int(w/2-cx*scale)-x0
 def crop(image):return image[y0:y1,x0:x1]
 def bounds(image):
  c=crop(image);mask=(c.max(2)-c.min(2)<65)&((c.max(2)<150)|(c.min(2)>100));ys=[np.flatnonzero(mask[:,i]) for i in range(center-2,center+3)];return float(np.median([p.min() for p in ys])),float(np.median([p.max() for p in ys]))
 samples={};first={}
 for variant in ['balanced','sync']:
  b=read(variant,0);top0,bottom0=bounds(b);rows=[]
  for weight in weights:
   image=read(variant,weight);top,bottom=bounds(image);rows.append({'weight':weight,'upperPixels':top-top0,'lowerPixels':bottom0-bottom})
  samples[variant]=rows;first[variant]={key:next(row['weight'] for row in rows if row[key]>=1) for key in ['upperPixels','lowerPixels']}
 assert abs(first['sync']['upperPixels']-first['sync']['lowerPixels'])<=.020001
 assert first['balanced']['lowerPixels']-first['balanced']['upperPixels']>=.059
 for key in ['upperPixels','lowerPixels']:assert abs(samples['balanced'][-1][key]-samples['sync'][-1][key])<=2
 at13=next(r for r in samples['sync'] if r['weight']==.13);assert at13['upperPixels']>at13['lowerPixels']>0
 ratio=samples['sync'][-1]['upperPixels']/(samples['sync'][-1]['upperPixels']+samples['sync'][-1]['lowerPixels']);assert .68<ratio<.72
 a=crop(read('sync',.13));b=crop(base);unchanged=int(((b.min(2)>180)&np.all(a==b,axis=2)).sum());assert unchanged>100
 report['eyes'].append({'side':side,'firstVisibleMovement':first,'samples':samples,'fullUpperShare':ratio,'unchangedBrightPixelsAt13Percent':unchanged})
(root/'results/sync-smile-onset.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
