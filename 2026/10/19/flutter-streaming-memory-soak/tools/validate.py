#!/usr/bin/env python3
import json,statistics
from pathlib import Path
root=Path(__file__).resolve().parent.parent
r=[json.loads(x)for x in (root/'results/soak-fixed.jsonl').read_text().splitlines()]
passes=[x for x in r if x['type']=='pass']
assert len(passes)==60 and r[-1]['ok'] is True
assert r[0]['ort_threads']==1 and r[0]['work_activity'] is True
for x in passes:
 assert x['samples']==9600000 and x['frames']==600 and x['vad_positive']==7002
 assert x['voice_retained']<=8 and x['frames_retained']<=8
 assert sum(x['metrics']['callbacks'].values())==0
 assert x['metrics']['ort']=={'sessions':1,'values':0}
 assert x['metrics']['rss']<512*1048576
closed=next(x for x in r if x['type']=='after_close');assert closed['metrics']['ort']=={'sessions':0,'values':0}
assert all(x['type']!='pressure_relief'for x in r)
tail=passes[10:]
def delta(k):return statistics.median(x['metrics'][k]for x in tail[-10:])-statistics.median(x['metrics'][k]for x in tail[:10])
ys=[x['metrics']['malloc_in_use']for x in tail];xs=list(range(len(ys)));mx=statistics.mean(xs);my=statistics.mean(ys);slope=sum((x-mx)*(y-my)for x,y in zip(xs,ys))/sum((x-mx)**2 for x in xs)
assert slope<32768,('live malloc slope',slope)
assert delta('rss')<8*1048576,('rss delta',delta('rss'))
assert delta('footprint')<8*1048576,('footprint delta',delta('footprint'))
for label,expected in [('profile-unfixed-heap-final',100),('profile-fixed-heap-final',0)]:
 p=json.loads((root/f'results/{label}.json').read_text());c={x['class']:x for x in p['interesting']}
 for name in ['PcmAnalysis','VoiceDetector','SileroVad','FrameAnalysis']:assert c[name]['instances']==expected
print(json.dumps({'passes':len(passes),'media_hours':sum(x['samples']/16000 for x in passes)/3600,'wall_seconds':r[-1]['wall_ms']/1000,'tail_rss_delta_bytes':delta('rss'),'tail_footprint_delta_bytes':delta('footprint'),'tail_live_malloc_slope_bytes_per_pass':slope},indent=2))
