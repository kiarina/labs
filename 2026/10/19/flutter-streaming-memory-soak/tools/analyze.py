#!/usr/bin/env python3
import json,statistics,math
from pathlib import Path
lab=Path(__file__).resolve().parent.parent
base=Path.home()/'Library/Containers/dev.lab.memorySoakLab/Data/Library/Application Support/dev.lab.memorySoakLab'
def load(label):return [json.loads(x)for x in (base/f'{label}.jsonl').read_text().splitlines()]
def slope(ys):
 xs=list(range(len(ys)));mx=statistics.mean(xs);my=statistics.mean(ys);return sum((x-mx)*(y-my)for x,y in zip(xs,ys))/sum((x-mx)**2 for x in xs) if len(ys)>1 else 0
out={}
for p in base.glob('*.jsonl'):
 rows=load(p.stem);passes=[r for r in rows if r['type']=='pass']
 if not passes:continue
 tail=passes[10:];delta=lambda field:statistics.median(x['metrics'][field]for x in tail[-10:])-statistics.median(x['metrics'][field]for x in tail[:10]) if tail else None
 out[p.stem]={'mode':rows[0]['mode'],'count':len(passes),'done':rows[-1].get('ok'),'first_rss':passes[0]['metrics']['rss'],'last_rss':passes[-1]['metrics']['rss'],'rss_delta_tail':delta('rss'),'footprint_delta_tail':delta('footprint'),'live_malloc_slope_tail':slope([x['metrics']['malloc_in_use']for x in tail]) if tail else None,'last_malloc':passes[-1]['metrics']['malloc_in_use'],'last_callbacks':passes[-1]['metrics']['callbacks'],'last_ort':passes[-1]['metrics']['ort'],'max_rss':max(x['metrics']['rss']for x in passes),'wall_ms':rows[-1].get('wall_ms'),'media_seconds':sum(r['samples']/16000 for r in passes)}
(lab/'work/summary.json').write_text(json.dumps(out,indent=2)+'\n')
for k,v in out.items():print(k,v['count'],v['done'],'RSS MiB',round(v['first_rss']/1048576,1),round(v['last_rss']/1048576,1),'live',round(v['last_malloc']/1048576,1),'callbacks',v['last_callbacks']['ffmpeg_complete'],'tail delta',None if v['rss_delta_tail'] is None else round(v['rss_delta_tail']/1048576,2))
