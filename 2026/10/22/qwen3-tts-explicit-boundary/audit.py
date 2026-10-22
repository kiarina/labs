"""Recompute first voiced playout time from measured arrivals and untouched PCM."""
import argparse,json
from pathlib import Path
import numpy as np
import soundfile as sf
p=argparse.ArgumentParser();p.add_argument('--output',default='output');args=p.parse_args();root=Path(args.output);rows=json.loads((root/'results.json').read_text())
for r in rows:
 stem=f"{r['mode']}-{r['case']}-{r['schedule']}-{r['seed']}"
 if not (root/f'{stem}.wav').exists() and r.get('error'):
  r['no_pcm']=True
  continue
 a,sr=sf.read(root/f'{stem}.wav',dtype='float32');events=json.loads((root/f'{stem}.json').read_text())['events'];rms=np.sqrt(np.mean(a[:len(a)//240*240].reshape(-1,240)**2,axis=1));active=np.flatnonzero(rms>.003)
 onset=(int(active[0])*240 if len(active) else len(a));clock=0;offset=0;audible=None
 for e in events:
  if e['type']!='pcm':continue
  clock=max(clock,e['t'])
  if offset<=onset<offset+e['samples']:audible=clock+(onset-offset)/sr
  clock+=e['samples']/sr;offset+=e['samples']
 assert offset==len(a) and sr==24000
 r['first_voiced_playout_s']=audible
 r['clipped_sample_count']=int(np.count_nonzero(np.abs(a)>=1))
 if r['seed']==42 and r['schedule']=='chars':sf.write(root/f'{stem}-listen.wav',a,sr,subtype='PCM_16')
(root/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
print('audited',len(rows),'rows')
