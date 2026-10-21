"""Make a compact, path-free evidence bundle from benchmark outputs."""
import argparse
import json
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('output',nargs='?',default='output')
parser.add_argument('--destination',default='results')
args=parser.parse_args()
output=Path(args.output); dest=Path(args.destination);dest.mkdir(exist_ok=True)
for name in ('environment.json','summary.json','buffer-probe.json','transcripts.json'):
    source=output/name
    if source.exists():
        (dest/name).write_text(source.read_text())
for source in output.glob('*.json'):
    if source.stem.startswith(('en_','ja_')):
        (dest/source.name).write_text(source.read_text())
summary=json.loads((output/'summary.json').read_text())
rows=['| Case | Trial | First PCM (s) | Close (s) | Audio (s) | RTF | Before close | Gap (s) |',
      '|---|---:|---:|---:|---:|---:|---|---:|']
for r in summary:
    m=r['metrics']
    if m:
        rows.append(f"| {r['case']} | {r['trial']} | {m['ttfp_s']:.3f} | {r['close_s']:.3f} | {m['audio_s']:.3f} | {m['rtf']:.3f} | {m['audio_before_close']} | {m['zero_prebuffer']['total_gap_s']:.3f} |")
    else:
        rows.append(f"| {r['case']} | {r['trial']} | Error: {r['error']} | | | | | |")
(dest/'table.md').write_text('\n'.join(rows)+'\n')
print('\n'.join(rows))

# Exact PCM parity checks for identical seeded text-token sequences.
import numpy as np
import soundfile as sf
pairs=[('en_all-1','en_words-1'),('en_words-1','en_starvation-1'),
       ('ja_all-1','ja_chars-1'),('ja_phrases_space-1','ja_starvation-1'),
       ('ja_phrases_space-0','ja_starvation-0')]
parity=[]
for a,b in pairs:
    if not (output/f'{a}.wav').exists() or not (output/f'{b}.wav').exists():
        continue
    x,sr=sf.read(output/f'{a}.wav',dtype='float32')
    y,sr2=sf.read(output/f'{b}.wav',dtype='float32')
    parity.append({'a':a,'b':b,'samples_a':len(x),'samples_b':len(y),
                   'sample_rates':[sr,sr2],'equal':bool(sr==sr2 and np.array_equal(x,y)),
                   'max_abs_diff':float(np.max(np.abs(x-y))) if x.shape==y.shape else None})
(dest/'waveform-parity.json').write_text(json.dumps(parity,indent=2)+'\n')

# Additional prebuffer tradeoffs computed from the same recorded arrivals.
tradeoffs=[]
for record in summary:
    timeline=json.loads((output/f"{record['case']}-{record['trial']}.json").read_text())
    events=[e for e in timeline['events'] if e['type']=='pcm']
    for threshold in (0.0,0.5,1.0,2.0):
        available=0.0; started=None; deadline=None; gap=0.0
        for e in events:
            duration=e['samples']/e['sr']
            if started is None:
                available+=duration
                if available<threshold and e is not events[-1]: continue
                started=e['received'];deadline=started+available
            else:
                gap+=max(0.0,e['received']-deadline)
                deadline=max(e['received'],deadline)+duration
        tradeoffs.append({'case':record['case'],'trial':record['trial'],
                          'prebuffer_s':threshold,'playback_start_s':started,'gap_s':gap})
(dest/'playback-tradeoffs.json').write_text(json.dumps(tradeoffs,indent=2)+'\n')
