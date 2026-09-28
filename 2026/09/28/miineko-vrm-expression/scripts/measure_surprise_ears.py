"""Compare fixed-camera endpoints; changes must remain in the upper ear region."""
import json
from pathlib import Path
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/surprise-ears-review';results=[]
for angle in [0,45,90,-45,-90]:
 a=np.array(Image.open(folder/f'surprise-ears-0-{angle}.png'));b=np.array(Image.open(folder/f'surprise-ears-1-{angle}.png'));diff=np.any(a!=b,axis=2);yy,xx=np.where(diff);assert len(yy)>100
 # Fixed orthographic camera: y=.84 is at 25.6% from the top of this canvas.
 assert not diff[int(a.shape[0]*.27):].any()
 results.append({'angle':angle,'changedPixels':len(yy),'changedBounds':[int(xx.min()),int(yy.min()),int(xx.max()),int(yy.max())],'lower73PercentIdentical':True})
(root/'results/surprise-ears-shape.json').write_text(json.dumps({'scope':'ear endpoint differences above face in five fixed views; not a semantic mesh segmentation proof','views':results},indent=2)+'\n');print(json.dumps(results))
