#!/usr/bin/env python3
"""Offline CER and request-latency evaluation. No model execution."""
import hashlib,json,statistics,unicodedata
from pathlib import Path
root=Path(__file__).resolve().parents[1];refs=json.loads((root/'fixtures/segments.json').read_text());by_id={r['id']:r for r in refs}
def norm(s):return ''.join(c for c in unicodedata.normalize('NFKC',s).lower()if not c.isspace()and not unicodedata.category(c).startswith('P'))
def distance(a,b):
 prev=list(range(len(b)+1))
 for i,x in enumerate(a,1):
  cur=[i]
  for j,y in enumerate(b,1):cur.append(min(cur[-1]+1,prev[j]+1,prev[j-1]+(x!=y)))
  prev=cur
 return prev[-1]
def p95(v):
 v=sorted(v);pos=(len(v)-1)*.95;a=int(pos);b=min(a+1,len(v)-1);return v[a]+(v[b]-v[a])*(pos-a)
reports={}
for name in ['apple','whisper']:
 data=json.loads((root/f'results/{name}.json').read_text());rows=[];trials=[]
 for row in data['rows']:
  ref=by_id[row['id']];a=norm(ref['reference']);b=norm(row['text']);rows.append({'id':row['id'],'speaker_id':row['speaker_id'],'trial':row['trial'],'reference':ref['reference'],'text':row['text'],'normalized_reference':a,'normalized_text':b,'edit_distance':distance(a,b),'reference_characters':len(a),'cer':distance(a,b)/len(a),'binding_ok':row['speaker_id']==ref['speaker_id'],'request_ms':row['request_seconds']*1000})
 for trial in range(3):
  rs=[r for r in rows if r['trial']==trial];den=sum(r['reference_characters']for r in rs);trials.append({'trial':trial,'cer':sum(r['edit_distance']for r in rs)/den,'edits':sum(r['edit_distance']for r in rs),'reference_characters':den,'nonempty':sum(bool(r['normalized_text'])for r in rs)})
 ms=[r['request_ms']for r in rows];warm=ms[1:]
 reports[name]={'trials':trials,'all_bindings_ok':all(r['binding_ok']for r in rows),'nonempty_requests':sum(bool(r['normalized_text'])for r in rows),'requests':len(rows),'first_request_ms':ms[0],'median_ms':statistics.median(ms),'p95_ms':p95(ms),'max_ms':max(ms),'after_first_median_ms':statistics.median(warm),'after_first_p95_ms':p95(warm),'all_requests_under_one_second':max(ms)<=1000,'cer_under_10_percent_all_trials':all(t['cer']<=.1 for t in trials),'rows':rows}
checks={'six_source_segments':len(refs)==6,'same_request_counts':reports['apple']['requests']==reports['whisper']['requests']==18,'ids_preserved':all(r['all_bindings_ok']for r in reports.values()),'no_empty_results':all(r['nonempty_requests']==18 for r in reports.values()),'no_reference_text_sent_to_apple_helper':'reference'not in(root/'Sources/SegmentASR/main.swift').read_text()}
# Semantic separation check: each trial has exactly one result per request,
# with final results completed before the next Analyzer is constructed.
for name in ['apple','whisper']:
 data=json.loads((root/f'results/{name}.json').read_text())
 checks[name+'_unique_requests']=all(len({r['id']for r in data['rows']if r['trial']==t})==6 for t in range(3))
 if name=='apple':checks['apple_final_events']=all(r['events']and all(e['final']for e in r['events'])for r in data['rows'])
stream=json.loads((root/'results/dart-stream.json').read_text());roundtrips=[r['dart_roundtrip_ms']for r in stream['rows']]
checks['dart_stream_12_bindings']=len(stream['rows'])==12 and all(r['binding_ok']for r in stream['rows'])
checks['dart_stream_no_reference']=not stream['reference_text_sent']
for row in stream['rows']:
 checks['dart_stream_final_'+str(len(checks))]=bool(row['events'])and all(e['final']for e in row['events'])
stream_summary={'requests':len(roundtrips),'process_startup_ms':stream['startup_ms'],'roundtrip_median_ms':statistics.median(roundtrips),'roundtrip_p95_ms':p95(roundtrips),'roundtrip_max_ms':max(roundtrips),'all_bindings_ok':all(r['binding_ok']for r in stream['rows'])}
result={'evidence_valid':all(checks.values()),'checks':checks,'normalization':'Unicode NFKC, lowercase, remove whitespace and Unicode punctuation; no numeric-word substitution','reference_scope':'six manually transcribed utterances aligned to retained SCD boundaries; small shared fixture, not a general benchmark','reports':reports,'dart_stream':stream_summary,'source_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()for p in [root/'fixtures/scd.json',root/'fixtures/reference.txt',root/'fixtures/segments.json']}}
(root/'results/comparison.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:{x:v for x,v in r.items()if x!='rows'}for k,r in reports.items()},ensure_ascii=False,indent=2));assert result['evidence_valid']
