"""Check visible central lid travel and unchanged highlight color where uncovered."""
from pathlib import Path
import json
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/balanced-smile-review'
def read(name):return np.array(Image.open(folder/(name+'.png')).convert('RGB')).astype(int)
base=read('neutral-0');h,w=base.shape[:2];scale=h/.82
report={'scope':'fixed frontal central five-column travel, not whole-eye area closure; uncovered bright source pixels retain color','eyes':[]}
for side,cx in [('L',.1764),('R',-.1848)]:
 x0=int(w/2-(cx+.10)*scale);x1=int(w/2-(cx-.10)*scale);y0=int((.64+.41-.75)*scale);y1=int((.64+.41-.51)*scale);center=int(w/2-cx*scale)-x0
 def crop(image):return image[y0:y1,x0:x1]
 def extent(image):
  c=crop(image);achromatic=(c.max(2)-c.min(2)<65)&((c.max(2)<150)|(c.min(2)>100));tops=[];bottoms=[]
  for x in range(center-2,center+3):
   ids=np.flatnonzero(achromatic[:,x]);assert len(ids)>3
   tops.append(int(ids.min()));bottoms.append(int(ids.max()))
  return float(np.median(tops)),float(np.median(bottoms))
 top0,bottom0=extent(base);base_white=crop(base).min(2)>180;samples=[]
 for weight in [.25,.5,.75,1]:
  current=read(f'balanced-happy-{weight}-0');top,bottom=extent(current);upper=top-top0;lower=bottom0-bottom;share=upper/(upper+lower);c=crop(current);white=c.min(2)>180;unchanged=np.all(c==crop(base),axis=2)
  samples.append({'weight':weight,'upperTravelPixels':upper,'lowerTravelPixels':lower,'upperShare':share,'brightPixels':int(white.sum()),'unchangedSourceBrightPixels':int((white&base_white&unchanged).sum())})
  assert upper>lower>=0 and .64<share<.76,(side,weight,share)
 assert samples[0]['unchangedSourceBrightPixels']>100
 assert samples[-1]['brightPixels']==0
 assert all(a['brightPixels']>=b['brightPixels'] for a,b in zip(samples,samples[1:]))
 report['eyes'].append({'side':side,'baselineTopPixel':top0,'baselineBottomPixel':bottom0,'baselineBrightPixels':int(base_white.sum()),'samples':samples})
(root/'results/balanced-smile-motion.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
