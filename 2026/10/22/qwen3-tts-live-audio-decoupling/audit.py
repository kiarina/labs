"""Audit saved measurements without loading a model or regenerating audio."""
import json
from pathlib import Path

folders=['output-screen','output-confirm','output-cache','output-cache-confirm','output-pause','output-recorded']
rows=[]
for folder in folders:
    folder=Path(folder)
    env=json.loads((folder/'environment.json').read_text())
    assert env['reference_samples']==256283
    assert env['reference_sha256']=='c03e2da1cf1877fc829168840d894fb846716c69d80d4f00ae4cdaafea96a5c0'
    for r in json.loads((folder/'results.json').read_text()):
        assert r['finite']
        stem=f"{r['mode']}-{r['case']}-{r['schedule']}-{r['seed']}"
        assert (folder/(stem+'.wav')).exists()
        raw=json.loads((folder/(stem+'.json')).read_text())
        if r['mode'].startswith('segments'):
            assert raw['trace']['segments'][-1]['through_chars']==len(r['text'])
            assert all(s['stop']=='eos' for s in raw['trace']['segments'])
        else:assert r['tokens_consumed']==r['tokens_total']
        rows.append(r)
for case in ['ja','en']:
    group=[r for r in rows if r['case']==case and r['seed']==42 and r['schedule']=='full' and r['mode'] in ['segments','segments_cached']]
    assert len(group)==2 and group[0]['pcm_sha256']==group[1]['pcm_sha256']
    for seed in [42,43,44]:
        group=[r for r in rows if r['case']==case and r['seed']==seed and r['schedule']=='chars' and r['mode'] in ['segments','segments_cached']]
        assert len(group)==2 and group[0]['pcm_sha256']==group[1]['pcm_sha256']
playout=json.loads(Path('results/playout.json').read_text())
selected=[r for r in playout if r['stem'].startswith('segments_cached') and '-pause-' not in r['stem']]
assert len(selected)==8
assert all(next(p for p in r['policies'] if p['hold_s']==1.)['gap_s']==0 for r in selected)
public=json.loads(Path('results/measurements.json').read_text())
assert all('asr' not in r['evaluation'] for r in public['measurements'])
print(json.dumps({'measurements':len(rows),'expected_frame_caps':sum(r['stop']=='frame_cap' for r in rows),'cached_pcm_parity_pairs':8,'continuous_1s_playout_cases':len(selected)}))
