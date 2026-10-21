"""Audit saved real outputs and score diagnostic ASR, without rerunning models."""
import argparse
import hashlib
import json
import unicodedata
from pathlib import Path
import numpy as np
import soundfile as sf

p=argparse.ArgumentParser();p.add_argument('folders',nargs='+');args=p.parse_args()
def norm(text):
    return ''.join(c for c in unicodedata.normalize('NFKC',text).lower() if not c.isspace() and unicodedata.category(c)[0] not in 'PZ')
def distance(a,b):
    row=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        new=[i]
        for j,y in enumerate(b,1):new.append(min(new[-1]+1,row[j]+1,row[j-1]+(x!=y)))
        row=new
    return row[-1]
for folder in args.folders:
    root=Path(folder);summary=json.loads((root/'summary.json').read_text());hashes={}
    for r in summary:
        assert r['error'] is None,r
        stem=f"{r['case']}-{r['trial']}";detail=json.loads((root/f'{stem}.json').read_text())
        assert detail['trace']['stop']=='eos'
        audio,sr=sf.read(root/f'{stem}.wav',dtype='float32')
        assert np.isfinite(audio).all()
        assert len(audio)==sum(e['samples'] for e in detail['events'] if e['type']=='pcm')
        assert len(audio)==len(detail['trace']['codes'])*1920
        assert not any(e['type'] in ('producer_error','error') for e in detail['events'])
        assert all(e.get('reached',True) for e in detail['events'])
        hashes[stem]=hashlib.sha256(audio.tobytes()).hexdigest()
    for pair in json.loads((root/'schedule-parity.json').read_text()):
        assert pair['code_equal'] and pair['pcm_equal']
        assert hashes[f"{pair['a']}-{pair['trial']}"]==hashes[f"{pair['b']}-{pair['trial']}"]
    scores=[]
    for r in json.loads((root/'transcripts.json').read_text())['results']:
        case=json.loads((root/r['file'].replace('.wav','.json')).read_text())
        a,b=norm(case['text']),norm(r['text']);d=distance(a,b)
        scores.append({'file':r['file'],'edit_distance':d,'reference_chars':len(a),'cer':d/len(a)})
    (root/'asr-scores.json').write_text(json.dumps(scores,indent=2))
    (root/'audit.json').write_text(json.dumps({'completed_eos_runs':len(summary),'pcm_sha256':hashes,
        'unique_waveforms':len(set(hashes.values())),'schedule_hashes_match':True},indent=2))
    print(folder,len(summary),'complete runs; unique waveforms:',len(set(hashes.values())), 'ASR CER:',[r['cer'] for r in scores])
