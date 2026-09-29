"""Read-only frontal artifact measurements; geometry/alpha preservation checked separately."""
from pathlib import Path
import json,numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/lid-rim-review'
def read(variant,pose):return np.array(Image.open(folder/f'{variant}-{pose}-0.png').convert('RGB')).astype(float)
a=read('highlight-clean-r','reference86');b=read('lid-rim-clean','reference86');h,w=a.shape[:2];yy,xx=np.mgrid[:h,:w];scale=h/.82;wx=(xx-w/2)/scale;wy=1.05-yy/scale
region=np.zeros((h,w),bool)
for cx in [.1764,-.1848]:
 r=np.hypot((wx-cx)/.104,(wy-.619)/.113);region|=(r>.60)&(r<1.05)&((wy>.66)|(wy<.54))
def dark_residual(image):
 lum=image[:,:,0];mean=sum(np.roll(np.roll(lum,dy,axis=0),dx,axis=1) for dx in [-5,0,5] for dy in [-5,0,5])/9
 return region&(mean-lum>10)
old=int(dark_residual(a).sum());new=int(dark_residual(b).sum());assert old>30 and new<old*.25,(old,new)
ink=[]
for pose in ['reference86','blink','happy','angry','sad','relaxed']:
 a=read('highlight-clean-r',pose);b=read('lid-rim-clean',pose);count=int(((a.max(2)<80)!=(b.max(2)<80)).sum());assert count<=3,(pose,count);ink.append({'pose':pose,'darkInkMaskDifferentPixels':count})
report={'scope':'fixed front 86% closure, high-frequency dark residual on top/bottom eye-rim bands; not all artifact types or lighting conditions','darkRimPixelsBefore':old,'darkRimPixelsAfter':new,'inkChecks':ink};(root/'results/lid-rim-pixels.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
