"""Per-mode summary of character-input runs (median and range over seeds)."""
import argparse
import json
import statistics as st
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('--output',default='output');args=p.parse_args();root=Path(args.output)
rows=json.loads((root/'results.json').read_text())
scores={s['file']:s for s in json.loads((root/'evaluation.json').read_text())['scores']}
modes=list(dict.fromkeys(r['mode'] for r in rows if r['case']!='warmup'))
summary=[]
for case in ['short','long']:
 for mode in modes:
  rs=[r for r in rows if r['mode']==mode and r['case']==case and r['schedule']=='chars']
  if not rs:continue
  sc=[scores[f"{mode}-{case}-chars-{r['seed']}.wav"] for r in rs]
  col=lambda k:[r[k] for r in rs]
  item={'case':case,'mode':mode,'n':len(rs),'required_prefix_tokens':rs[0]['required_prefix_tokens'],
   'first_pcm_s':st.median(col('first_pcm_s')),'first_voiced_s':st.median(col('first_voiced_playout_s')),
   'first_voiced_range':[min(col('first_voiced_playout_s')),max(col('first_voiced_playout_s'))],
   'text_done_s':st.median(col('text_done_s')),'before_done':sum(col('before_done')),
   'gap_s':st.median(col('gap_s')),'gap_range':[min(col('gap_s')),max(col('gap_s'))],
   'ecapa_mean':st.mean(s['ecapa_cos'] for s in sc),'ecapa_range':[min(s['ecapa_cos'] for s in sc),max(s['ecapa_cos'] for s in sc)],
   'cer_pct':[round(100*s['cer'],2) for s in sc],'stops':sorted(set(col('stop'))),'clipped':sum(col('clipped_sample_count'))}
  summary.append(item)
  print(f"{case:5s} {mode:20s} req={item['required_prefix_tokens']:3d} pcm={item['first_pcm_s']:5.2f} voice={item['first_voiced_s']:5.2f}"
   f" done={item['text_done_s']:5.2f} early={item['before_done']}/{item['n']} gap={item['gap_s']:.2f}[{item['gap_range'][1]:.2f}]"
   f" cos={item['ecapa_mean']:.3f}[{item['ecapa_range'][0]:.3f}-{item['ecapa_range'][1]:.3f}] cer={item['cer_pct']} stop={item['stops']} clip={item['clipped']}")
pooled={}
for mode in modes:
 c=[it['ecapa_mean'] for it in summary if it['mode']==mode]
 vals=[scores[f"{mode}-{case}-chars-{r['seed']}.wav"]['ecapa_cos'] for case in ['short','long'] for r in rows if r['mode']==mode and r['case']==case and r['schedule']=='chars']
 pooled[mode]={'n':len(vals),'mean':st.mean(vals),'min':min(vals),'max':max(vals)}
 print(f"pooled {mode:20s} n={len(vals)} mean={st.mean(vals):.3f} [{min(vals):.3f}-{max(vals):.3f}]")
print('errors',sum(1 for r in rows if r.get('error')))
(root/'summary.json').write_text(json.dumps({'by_case':summary,'pooled_ecapa':pooled},ensure_ascii=False,indent=2))
