"""Arrival-time listening files; gaps are inserted, original audio not stretched."""
import argparse,json
from pathlib import Path
import numpy as np
import soundfile as sf
p=argparse.ArgumentParser();p.add_argument('--output',default='output');args=p.parse_args();root=Path(args.output)
rows=json.loads((root/'results.json').read_text())
for row in rows:
 if row['schedule']!='chars' or row['seed']!=42:continue
 stem=f"{row['mode']}-{row['case']}-chars-42";data=json.loads((root/f'{stem}.json').read_text());pcm,sr=sf.read(root/f'{stem}.wav',dtype='float32')
 events=[e for e in data['events'] if e['type']=='pcm'];chunks=[];cursor=0;clock=0
 for e in events:
  arrival=round(e['t']*sr)
  if arrival>clock:chunks.append(np.zeros(arrival-clock,dtype=np.float32));clock=arrival
  chunk=pcm[cursor:cursor+e['samples']];chunks.append(chunk);cursor+=len(chunk);clock+=len(chunk)
 sf.write(root/f'{stem}-arrival.wav',np.concatenate(chunks),sr,subtype='PCM_16')
 print(stem, 'arrival replay seconds',clock/sr)
# Fixed A/B presentation; mapping is explicit in report, no random candidate selection.
(root/'listening.csv').write_text('case,file,voice_similarity_1to5,naturalness_1to5,comments\n'+''.join(f"{r['case']},{r['mode']}-{r['case']}-chars-42.wav,,,\n" for r in rows if r['schedule']=='chars' and r['seed']==42))
