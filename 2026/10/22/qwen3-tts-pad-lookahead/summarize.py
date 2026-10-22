"""Per-mode summary of character-input runs, and a public export without ASR text.

ASR strings can contain the private reference transcript (that is the leak
being measured), so results/ keeps only counts, CER and hashes.
"""
import argparse
import json
import shutil
import statistics as st
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('--output',default='output');p.add_argument('--export');args=p.parse_args();root=Path(args.output)
rows=json.loads((root/'results.json').read_text())
evaluation=json.loads((root/'evaluation.json').read_text());scores={s['file']:s for s in evaluation['scores']}
modes=list(dict.fromkeys(r['mode'] for r in rows))
med=lambda xs:st.median(xs) if xs else None
# The long text's 2nd sentence; heard twice when the talker backtracks after the
# 3rd sentence starts (the loop seen in PAD runs). Counts only, never exported text.
LOOP_PHRASE='ゆっくりでいいからね'
summary=[]
for case in ['short','long','long_alt']:
 for mode in modes:
  rs=[r for r in rows if r['mode']==mode and r['case']==case and r['schedule']=='chars']
  if not rs:continue
  sc=[scores.get(f"{mode}-{case}-chars-{r['seed']}.wav",{}) for r in rs]
  ok=[r for r in rs if not r.get('error')]
  col=lambda k:[r[k] for r in ok if r.get(k) is not None]
  leaks=[s.get('reference_overlap_before_target') for s in sc]
  item={'case':case,'mode':mode,'n':len(rs),'errors':len(rs)-len(ok),'stops':sorted({str(r.get('stop')) for r in rs}),
   'required_tokens':rs[0]['required_prefix_tokens'],'first_pcm_s':med(col('first_pcm_s')),'first_voiced_s':med(col('first_voiced_playout_s')),
   'text_done_s':med(col('text_done_s')),'before_done':sum(col('before_done')),'gap_s':med(col('gap_s')),
   'ecapa':[None if s.get('ecapa_cos') is None else round(s['ecapa_cos'],3) for s in sc],
   'cer_pct':[None if s.get('cer') is None else round(100*s['cer'],1) for s in sc],
   'chars_before_target':[s.get('chars_before_target') for s in sc],'reference_overlap':leaks,
   'leaks':sum(1 for x in leaks if x is not None and x>=8),
   'loops':sum(1 for s in sc if s.get('asr','').count(LOOP_PHRASE)>=2),
   'cutoffs':sum(1 for s in sc if s.get('cer') is not None and s['cer']>=.4)}
  summary.append(item)
  fmt=lambda v:'—' if v is None else f'{v:5.2f}'
  print(f"{case:5s} {mode:13s} req={item['required_tokens']:3d} pcm={fmt(item['first_pcm_s'])} voice={fmt(item['first_voiced_s'])} early={item['before_done']}/{len(ok)}"
   f" gap={fmt(item['gap_s'])} ecapa={item['ecapa']} cer={item['cer_pct']} pre={item['chars_before_target']} refoverlap={leaks} leak/loop/cut={item['leaks']}/{item['loops']}/{item['cutoffs']} err={item['errors']} stop={item['stops']}")
(root/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
if args.export:
 dest=Path(args.export);dest.mkdir(parents=True,exist_ok=True)
 for name in ['results.json','environment.json','summary.json']:shutil.copy(root/name,dest/name)
 public=dict(evaluation,scores=[{k:v for k,v in s.items() if k!='asr'} for s in evaluation['scores']])
 (dest/'evaluation.json').write_text(json.dumps(public,ensure_ascii=False,indent=2))
 print('exported to',dest)
