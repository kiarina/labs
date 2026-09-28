"""Raster checks for the connected-vowel probe; no all-pose guarantees."""
import json
from pathlib import Path
from collections import deque
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/connected-vowels'
evaluation=json.loads((root/'results/connected-vowels-evaluation.json').read_text())
def read(name):return np.array(Image.open(folder/(name+'.png')).convert('RGB')).astype(int)
base=read('base-0');height,width=base.shape[:2]
# World y=.49 separates the preserved nose from the mouth. Orthographic half-height=.41.
cutoff=int(height*(.64+.41-.49)/.82)
old_black=base.max(2)<85
old_red=(base[:,:,0]>80)&(base[:,:,0]>3*np.maximum(1,base[:,:,1]))&(base[:,:,0]>3*np.maximum(1,base[:,:,2]))
report={'canvasSize':[width,height],'scope':'frontal raster samples; preserved upper face and separate left/right rim connectivity, not all-pose geometry proof','samples':[]}
def measure(name):
 current=read(name);assert np.array_equal(base[:cutoff],current[:cutoff]),name
 black=current.max(2)<85;red=(current[:,:,0]>80)&(current[:,:,0]>3*np.maximum(1,current[:,:,1]))&(current[:,:,0]>3*np.maximum(1,current[:,:,2]))&~old_red
 connections=[]
 for left,right in [(0,width//2-2),(width//2+2,width)]:
  mask=black[cutoff:,left:right];old=old_black[cutoff:,left:right];seed=old&mask;seen=seed.copy();queue=deque(map(tuple,np.argwhere(seed)))
  while queue:
   y,x=queue.popleft()
   for dy in [-1,0,1]:
    for dx in [-1,0,1]:
     yy,xx=y+dy,x+dx
     if 0<=yy<len(mask) and 0<=xx<mask.shape[1] and mask[yy,xx] and not seen[yy,xx]:seen[yy,xx]=True;queue.append((yy,xx))
  added=mask&~old;n=int(added.sum());connected=int((added&seen).sum())
  if n>10:assert connected/n>.98,(name,left,n,connected)
  connections.append({'newRimPixels':n,'connectedToW':connected})
 return {'name':name,'redPixels':int(red.sum()),'cornerConnections':connections,'upperFaceExact':True}
for state in evaluation['states']:
 if state['angle']=='0':report['samples'].append(measure(state['name']))
for vowel in ['aa','ih','ou','ee','oh']:
 samples=[s for s in report['samples'] if s['name'].startswith(vowel+'-')]
 assert samples[0]['redPixels']==0 and samples[-1]['redPixels']>100
 assert all(a['redPixels']<=b['redPixels'] for a,b in zip(samples,samples[1:]))
report['onset']=[measure(f'early-{v}-{w}') for v in ['aa','ih','ou','ee','oh'] for w in [.1,.25]]
accepted=read('accepted-aa');current=read('aa-1-0');delta=np.abs(accepted-current)
report['aaAgainstAccepted']={'changedPixels':int(np.any(delta>0,axis=2).sum()),'maxChannelDifference':int(delta.max()),'meanAbsoluteChannelDifference':float(delta.mean()),'upperFaceExact':bool(np.array_equal(accepted[:cutoff],current[:cutoff]))}
assert report['aaAgainstAccepted']['upperFaceExact']
(root/'results/connected-vowels-contact.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
