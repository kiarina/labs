"""Read-only pixel comparison of the rendered local shading repair."""
import json
from pathlib import Path
from PIL import Image
import numpy as np
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/highlight-review'
def read(name):return np.array(Image.open(folder/name).convert('RGB')).astype(int)
a=read('blink-aligned-detail.png');b=read('highlight-clean-r-detail.png');diff=np.any(a!=b,axis=2);yy,xx=np.where(diff);assert len(xx)>0 and xx.max()<a.shape[1]/2
roi=np.zeros(diff.shape,dtype=bool);roi[yy.min():yy.max()+1,xx.min():xx.max()+1]=True
brightened=roi&(a.max(2)<160)&(b.min(2)>180);assert brightened.sum()>10
closed=[]
for pose in ['blink','happy','angry','sad','relaxed']:
 for angle in ['0','45','-45','90','-90']:
  x=read(f'blink-aligned-{pose}-{angle}.png');y=read(f'highlight-clean-r-{pose}-{angle}.png');count=int(np.any(x!=y,axis=2).sum());assert count==0,(pose,angle,count);closed.append({'pose':pose,'angle':angle})
report={'scope':'front detail: changes remain on screen-left eye; formerly dark pixels become bright; fully covered highlights give identical renders','changedBounds':[int(xx.min()),int(yy.min()),int(xx.max()),int(yy.max())],'changedPixels':int(diff.sum()),'formerlyDarkNowBrightPixels':int(brightened.sum()),'oppositeEyeAndOutsideLocalBoxIdentical':True,'closedStatesIdentical':closed};(root/'results/highlight-normal-pixels.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='closedStatesIdentical'}))
