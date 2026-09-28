"""Independent geometry, texture and projected-width checks for mouth depth."""
from pathlib import Path
import hashlib,json,struct
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];folder=root/'artifacts/mouth-flush'
a=np.load(root/'artifacts/feature-mouth-flush/audit.npz');before,after=a['before'],a['after'];changed=np.any(before!=after,axis=1)
assert np.array_equal(before[a['protected']],after[a['protected']])
assert np.array_equal(before[a['nose']],after[a['nose']])
assert np.array_equal(before[:,[0,2]],after[:,[0,2]])
assert np.max(a['sourceSurfaceDistance'])<2e-7
joining=changed&~a['core'];assert np.max(a['boundaryDistance'][joining])<=.002
assert np.all(after[:,1]>=before[:,1])
def texture_hashes(path):
 raw=path.read_bytes();n=struct.unpack_from('<I',raw,12)[0];doc=json.loads(raw[20:20+n]);blob=raw[28+n:];hashes=[]
 for image in doc['images']:
  view=doc['bufferViews'][image['bufferView']];start=view.get('byteOffset',0);hashes.append(hashlib.sha256(blob[start:start+view['byteLength']]).hexdigest())
 return sorted(hashes)
assert texture_hashes(root/'artifacts/feature-eyes/continuous-blink.vrm')==texture_hashes(root/'artifacts/feature-mouth-flush/continuous-blink.vrm')
def image(name):return np.array(Image.open(folder/name).convert('RGB')).astype(int)
old=image('eyes-flat-color.png');new=image('mouth-flush-flat-color.png')
# Fixed 900 x 1000 frontal captures. Flat source-color rendering removes lighting
# as a confound when checking that the original mouth artwork was not narrowed.
old_mask=old[710:800,330:570].max(2)<80;new_mask=new[710:800,330:570].max(2)<80
def bounds(mask):
 y,x=np.where(mask);return [int(x.min()),int(y.min()),int(x.max()),int(y.max())]
assert bounds(old_mask)==bounds(new_mask)
iou=float((old_mask&new_mask).sum()/(old_mask|new_mask).sum());ratio=float(new_mask.sum()/old_mask.sum())
assert iou>.99 and .99<ratio<1.01,(iou,ratio)
stem_old=old[707:724,420:480].max(2)<80;stem_new=new[707:724,420:480].max(2)<80
assert bounds(stem_old)==bounds(stem_new)
stem_iou=float((stem_old&stem_new).sum()/(stem_old|stem_new).sum());assert stem_iou>.99
old_lit=image('eyes-0.png');new_lit=image('mouth-flush-0.png');difference=abs(old_lit-new_lit).max(2)
outside=np.ones(difference.shape,bool);outside[:120]=False;outside[685:810,305:595]=False
assert difference[outside].max()<=2
# Side-view black area is a visible change metric, not a physical volume.
old_side=image('eyes-mouth-90.png')[725:773,100:200].max(2)<75
new_side=image('mouth-flush-90.png')[725:773,100:200].max(2)<75
side_ratio=float(new_side.sum()/old_side.sum());assert side_ratio<.7,side_ratio
report={'scope':'geometry/texture preservation and fixed-view image samples; not all-pose certification','protectedCoordinatesExact':True,'noseCoordinatesExact':True,'xzExact':True,'sourceSurfaceMaxDistance':float(a['sourceSurfaceDistance'].max()),'changedMouthVertices':int(changed.sum()),'changedJoiningVertices':int(joining.sum()),'maximumJoiningDistance':float(a['boundaryDistance'][joining].max()),'embeddedTexturesByteIdentical':True,'frontArtwork':{'sourcePixels':int(old_mask.sum()),'candidatePixels':int(new_mask.sum()),'bounds':bounds(old_mask),'intersectionOverUnion':iou,'pixelCountRatio':ratio},'stemArtwork':{'sourcePixels':int(stem_old.sum()),'candidatePixels':int(stem_new.sum()),'bounds':bounds(stem_old),'intersectionOverUnion':stem_iou},'outsideMouthMaxChannelDifference':int(difference[outside].max()),'noseLowerCropMaxChannelDifference':int(difference[620:710,400:500].max()),'sideMouth':{'sourceBlackPixels':int(old_side.sum()),'candidateBlackPixels':int(new_side.sum()),'pixelCountRatio':side_ratio}}
(root/'results/mouth-flush-preservation.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
