"""Print the events and stats of one app report (work/report-*.json)."""
import json,sys
r=json.load(open(sys.argv[1]))
print({k:r.get(k) for k in ['platform','config','download_ms','load_ms','asr','error']})
for k in ['replay','replay_warm']:
  x=r.get(k) or {}
  print(k, 'done_ms', x.get('done_ms'), 'after_end_ms', x.get('latency_after_end_ms'))
  for e in x.get('events',[]):
    print('  ',e['kind'],e['start'],e['end'],e.get('speaker'),e.get('text') or [t['label'] for t in e.get('tags',[])],e.get('asr_ms'),'lag',e.get('lag_s'))
print(json.dumps(r.get('stats')))
