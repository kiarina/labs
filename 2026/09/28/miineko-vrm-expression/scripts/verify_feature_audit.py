"""Check serialized coordinate audit plus visible skin/nose preservation."""
from pathlib import Path
import json
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parents[1];results=[]
for name in ['eyes','eyes-mouth']:
 a=np.load(root/f'artifacts/feature-{name}/audit.npz')
 before,after=a['before'],a['after'];protected=a['protected'];nose=a['noseStem']
 assert np.array_equal(before[protected],after[protected])
 assert np.array_equal(before[nose],after[nose])
 assert np.array_equal(before[a['pinkTriangles']],after[a['pinkTriangles']])
 assert np.array_equal(before[:,[0,2]],after[:,[0,2]])
 original=np.array(Image.open(root/'artifacts/feature-study/original-0.png').convert('RGB')).astype(int)
 candidate=np.array(Image.open(root/f'artifacts/feature-study/{name}-0.png').convert('RGB')).astype(int)
 assert original.shape==candidate.shape
 # Fixed 900x1000 capture, same header and projection. Exclude the eye/W artwork
 # when testing pink image samples: reflections there belong to the features.
 R,G,B=original[:,:,0],original[:,:,1],original[:,:,2]
 pink=(R>np.maximum(32,G*1.6))&(B>np.maximum(16,G*1.2))
 pink[470:685,145:750]=False;pink[710:790,350:550]=False
 difference=abs(original-candidate);values=difference[pink]
 skin_max=int(values.max(initial=0));nose_max=int(difference[620:715,400:500].max(initial=0))
 assert skin_max<=2,(name,skin_max)
 assert nose_max<=2,(name,nose_max)
 results.append({'variant':name,'protectedVertexCount':int(protected.sum()),'pinkTriangleCount':len(a['pinkTriangles']),'noseStemVertices':int(nose.sum()),'protectedCoordinatesExact':True,'noseCoordinatesExact':True,'pinkPixelSamples':int(pink.sum()),'pinkPixelMaxDifference':skin_max,'noseCropMaxDifference':nose_max})
(root/'results/feature-preservation.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results))
