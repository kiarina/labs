#!/usr/bin/env python3
"""Retained evidence only. Lexical labels are evaluation data, never model input."""
import json,re,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def evaluate(mode):
 r=json.loads((ROOT/f'results/boundary-{mode}.json').read_text());fs=[e for e in r['events']if e['type']=='input_transcript.added'];full=''.join(e['text']for e in fs)
 starts=[0]+[full.index(s)for s in ['うん','こっちは','了解','助']]+[next(m.start()for m in re.finditer('ほんと|本当',full))]
 labeled=[];cursor=0
 for f in fs:
  labels=[]
  for j,c in enumerate(f['text'],cursor):
   if c.isalnum():labels.append(max(i for i,v in enumerate(starts)if v<=j))
  labeled.append((f,labels));cursor+=len(f['text'])
 acks=[e for e in r['events']if e['type']=='session.context.appended'];ds=[e for e in r['events']if e['type']=='delegation.created'];rows=[]
 for i,b in enumerate(r['boundaries']):
  previous=[f['arrival_seconds']for f,ls in labeled if i in ls]
  ack=acks[i]['arrival_seconds']if i<len(acks)else None
  row={'boundary':b['id'],'transcript_tail_after_boundary_ms':round(1000*(max(previous)-b['at']),1)}
  if ack is not None:
   row.update(ack_latency_ms=round((ack-b['at'])*1000,1),completed_speaker_chars_after_ack=sum(sum(label<=i for label in ls)for f,ls in labeled if f['arrival_seconds']>ack))
  rows.append(row)
 wrong=total=0
 if acks:
  for f,ls in labeled:
   assigned=min(5,sum(e['arrival_seconds']<=f['arrival_seconds']for e in acks))%2
   total+=len(ls);wrong+=sum(label%2!=assigned for label in ls)
 return {'mode':mode,'fragments':len(fs),'boundary_commands':len([c for c in r['commands']if c['command']['type']=='session.context.append']),'acknowledgments':len(acks),'delegations':len(ds),'matched_boundary_events':sum(any(b['id']in json.dumps(d.get('content',[]))for d in ds)for b in r['boundaries']),'output_nonzero_samples':r.get('output_nonzero_samples'),'rows':rows,'ack_as_boundary_wrong_speaker_characters':wrong if acks else None,'evaluated_characters':total if acks else sum(len(ls)for _,ls in labeled),'evaluation_scope':'lexical six-utterance labels; fragment arrival grouping; punctuation excluded; not word timing truth','dedicated_errors':[e['error']for e in r['events']if e['type']=='error']}
reports=[evaluate(m)for m in ['baseline','markers','immediate']]
checks={m['mode']:{'six_boundaries':len(m['rows'])==6,'transcript_present':m['fragments']>0}for m in reports}
checks['markers_protocol']={'two_commit_rejections':len(reports[1]['dedicated_errors'])==2,'six_acks':reports[1]['acknowledgments']==6,'no_completion_event_observed':reports[1]['matched_boundary_events']==0,'late_characters_observed':all(v['completed_speaker_chars_after_ack']>0 for v in reports[1]['rows'])}
r={'evidence_valid':all(all(v.values())for v in checks.values()),'checks':checks,'reports':reports,'transcript_barrier_established':False,'current_code_sha256':{f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest()for f in ['tools/boundary_probe.py','asr/app/assets/refine-reference.json']}}
(ROOT/'results/boundary-validation.json').write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n');print(json.dumps(r,ensure_ascii=False,indent=2))
assert r['evidence_valid']
