"""Copy compact, public evidence and derive playout buffering from timestamps."""
import argparse
import json
from pathlib import Path
import numpy as np
import soundfile as sf

p=argparse.ArgumentParser();p.add_argument('folder');p.add_argument('--destination',required=True);args=p.parse_args()
root=Path(args.folder);dest=Path(args.destination);dest.mkdir(exist_ok=True,parents=True)
for file in root.glob('*.json'):
    (dest/file.name).write_text(file.read_text())
rows=['| Case | Trial | First PCM (s) | Close (s) | Audio (s) | RTF | Before close | Gap (s) |',
      '|---|---:|---:|---:|---:|---:|---|---:|']
playout=[]
for file in sorted(root.glob('*-?.json')):
    r=json.loads(file.read_text())
    if 'metrics' not in r:continue
    m=r['metrics']
    if m: rows.append(f"| {r['case']} | {r['trial']} | {m['first_pcm_s']:.3f} | {format(m['close_s'],'.3f') if m['close_s'] is not None else '—'} | {m['audio_s']:.3f} | {m['rtf']:.3f} | {m['before_close']} | {m['gap_s']:.3f} |")
    if r['error']:rows.append(f"| {r['case']} error | {r['trial']} | {r['error']} | | | | | |")
    events=[e for e in r['events'] if e['type']=='pcm']
    for threshold in (0.,.32,.64,1.):
        available=0.;start=None;deadline=None;gap=0.
        for e in events:
            duration=e['samples']/e['sr']
            if start is None:
                available+=duration
                if available<threshold and e is not events[-1]:continue
                start=e['t'];deadline=start+available
            else:
                gap+=max(0.,e['t']-deadline);deadline=max(e['t'],deadline)+duration
        playout.append({'case':r['case'],'trial':r['trial'],'prebuffer_s':threshold,'start_s':start,'gap_s':gap})
(dest/'table.md').write_text('\n'.join(rows)+'\n')
(dest/'playout.json').write_text(json.dumps(playout,indent=2))
print('\n'.join(rows))
