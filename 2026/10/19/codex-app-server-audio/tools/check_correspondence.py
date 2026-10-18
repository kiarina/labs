#!/usr/bin/env python3
"""Evaluate boundary guards on one retained dialogue; no network or inference.
Text markers are evaluation labels only; the binding policy never sees them.
"""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1];r=json.loads((root/'results/refined-asr-fixture.json').read_text());fs=r['fragments'];full=''.join(f['text']for f in fs)
markers=['もしもし','うん','こっちは','了解','助','本当'];starts=[full.index(v)for v in markers];roles=[0,1,0,1,0,1];expected=[];cursor=0
for f in fs:
 values=set()
 for i,c in enumerate(f['text'],cursor):
  if c.isalnum():values.add(roles[max(j for j,start in enumerate(starts)if start<=i)])
 expected.append(values);cursor+=len(f['text'])
# The new tracker labels the second person first. This observed permutation is
# an evaluation correspondence, not a hard-coded part of the runtime policy.
role_for_id={'speaker-2':0,'speaker-1':1}
rows=[]
for guard in [.2,.4,.6,.8,1.0,1.2]:
 correct=wrong=held=mixed=0;assignments=[]
 for f,truth in zip(fs,expected):
  if 'source_start'not in f:held+=1;assignments.append(None);continue
  a=f['source_start']-guard;b=f['source_end']+guard;candidates=set()
  # Look over the entire uncertainty range, not just points inside the nominal
  # interval. This makes a nearby speaker change a reason to withhold identity.
  t=max(0,a)
  while t<=b:
   matches=[v for v in r['speaker_intervals']if v['speaker_id']is not None and v['start']<=t<=v['end']]
   if matches:
    newest=max(v['available_ms']for v in matches);candidates.update(v['speaker_id']for v in matches if v['available_ms']==newest)
   t+=.02
  speaker=next(iter(candidates))if len(candidates)==1 else None;assignments.append(speaker)
  if speaker is None:held+=1
  elif len(truth)!=1:mixed+=1
  elif role_for_id[speaker]in truth:correct+=1
  else:wrong+=1
 rows.append({'guard_seconds':guard,'correct':correct,'wrong':wrong,'mixed_assigned':mixed,'held':held,'assignments':assignments})
report={'scope':'One retained two-speaker dialogue; text roles manually represented by evaluation-only boundary markers; not a word-timing gold corpus','clock_method':r['clock_origin_method'],'fragments':len(fs),'sweep':rows,'complete_word_alignment':False}
print(json.dumps(report,ensure_ascii=False,indent=2))
