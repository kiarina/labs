"""Check the visible opening and each side's connection to the original W."""
import json
from pathlib import Path
from collections import deque
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/connected-aa'
def read(name):return np.array(Image.open(folder/name).convert('RGB')).astype(int)
base=read('base-0.png');old=base[735:845,340:560];old_black=old.max(2)<85
report={'scope':'fixed frontal raster samples; each half tested separately; not continuous geometry proof','samples':[]}
for weight in [0,.1,.25,.4,.5,.65,.75,.9,1]:
 current=read(f'aa-{weight:g}-0.png');crop=current[735:845,340:560]
 assert np.array_equal(base[148:730],current[148:730]),'Opening changed the eye/nose region'
 red=(crop[:,:,0]>80)&(crop[:,:,0]>3*np.maximum(1,crop[:,:,2]))&(crop[:,:,0]>3*np.maximum(1,crop[:,:,1]))
 old_red=(old[:,:,0]>80)&(old[:,:,0]>3*np.maximum(1,old[:,:,2]))&(old[:,:,0]>3*np.maximum(1,old[:,:,1]))
 red&=~old_red;black=crop.max(2)<85;connections=[]
 for left,right in [(0,108),(112,220)]:
  mask=black[:,left:right];seed=old_black[:,left:right]&mask;seen=seed.copy();queue=deque(map(tuple,np.argwhere(seed)))
  while queue:
   y,x=queue.popleft()
   for dy in [-1,0,1]:
    for dx in [-1,0,1]:
     yy,xx=y+dy,x+dx
     if 0<=yy<len(mask) and 0<=xx<mask.shape[1] and mask[yy,xx] and not seen[yy,xx]:seen[yy,xx]=True;queue.append((yy,xx))
  added=mask&~old_black[:,left:right];n=int(added.sum());connected=int((added&seen).sum())
  if n>10:assert connected/n>.98,(weight,left,n,connected)
  connections.append({'newRimPixels':n,'connectedToSourceW':connected})
 report['samples'].append({'weight':weight,'redPixels':int(red.sum()),'cornerConnections':connections,'headNosePixelsExact':True})
assert report['samples'][0]['redPixels']==0
assert report['samples'][-1]['redPixels']>1000
assert all(a['redPixels']<=b['redPixels'] for a,b in zip(report['samples'],report['samples'][1:]))
(root/'results/connected-aa-contact.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
