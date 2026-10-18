#!/usr/bin/env python3
"""Offline lexical segment checks of retained two-peer calls, never sends text."""
import json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def inspect(mode):
 r=json.loads((ROOT/f'results/two-connections-{mode}.json').read_text());lanes=[]
 for lane in r['lanes']:
  segs=[s for s in r['segments']if s['connection']==lane['connection']];fs=[e for e in lane['events']if e['type']=='input_transcript.added'];full=''.join(f['text']for f in fs)
  markers=['こっちは','助']if lane['connection']=='A'else['了解','ほんと|本当']
  starts=[0];missing=[]
  for marker in markers:
   m=re.search(marker,full)
   if m:starts.append(m.start())
   else:missing.append(marker)
  if missing:
   lanes.append({'connection':lane['connection'],'full_transcript':full,'missing_lexical_markers':missing,'binding_evaluated':False,'output_nonzero_samples':lane['output_nonzero_samples'],'assistant_fragments':sum(e['type']=='output_transcript.added'for e in lane['events']),'errors':lane['errors'],'normal_turns':lane['normal_turns'],'sent_segments':lane['sent_segments']});continue
  rows=[{'id':s['id'],'source_start':s['start'],'source_end':s['end'],'play_start':s.get('play_start',s['start']),'play_end':s.get('play_start',s['start'])+s['end']-s['start'],'queue_wait_ms':s.get('queue_wait_ms',0),'first_text':None,'last_text':None,'characters':0,'characters_arriving_after_reuse':0}for s in segs];wrong=chars=0;cursor=0
  for f in fs:
   now=f['source_arrival'];active=max((i for i,s in enumerate(segs)if s.get('play_start',s['start'])<=now),default=0)
   for i,c in enumerate(f['text'],cursor):
    if not c.isalnum():continue
    truth=max(j for j,start in enumerate(starts)if start<=i);row=rows[truth];row['first_text']=now if row['first_text']is None else min(row['first_text'],now);row['last_text']=now;row['characters']+=1;chars+=1;wrong+=truth!=active
    if truth+1<len(segs)and now>=segs[truth+1].get('play_start',segs[truth+1]['start']):row['characters_arriving_after_reuse']+=1
   cursor+=len(f['text'])
  reuse=[]
  for i,row in enumerate(rows):
   row['first_text_latency_ms']=round((row['first_text']-row['source_start'])*1000,1)if row['first_text']is not None else None
   row['tail_after_actual_send_end_ms']=round((row['last_text']-row['play_end'])*1000,1)if row['last_text']is not None else None
   row['tail_latency_ms']=round((row['last_text']-row['source_end'])*1000,1)if row['last_text']is not None else None
   if i+1<len(segs):
    nextstart=segs[i+1].get('play_start',segs[i+1]['start']);last=max((f['source_arrival']for f in fs if f['source_arrival']<nextstart),default=-1e6)
    candidate=max(row['play_end']+1,last+1)
    reuse.append({'previous':row['id'],'next':segs[i+1]['id'],'source_silence_between_ms':round((nextstart-row['play_end'])*1000,1),'actual_tail_margin_before_reuse_ms':round((nextstart-row['last_text'])*1000,1),'last_text_before_reuse':last,'quiet_guard_additional_wait_ms':round(max(0,candidate-nextstart)*1000,1),'quiet_guard_would_allow_now':candidate<=nextstart})
  sent_exact=all(lane['sent_segments'].get(s['id'],{}).get('samples')==s['end_sample']-s['start_sample']for s in segs)
  lanes.append({'connection':lane['connection'],'full_transcript':full,'binding_evaluated':True,'fragments':len(fs),'characters':chars,'wrong_segment_characters_if_assign_on_reuse':wrong,'rows':rows,'reuse':reuse,'sent_samples_match_segments':sent_exact,'output_nonzero_samples':lane['output_nonzero_samples'],'assistant_fragments':sum(e['type']=='output_transcript.added'for e in lane['events']),'errors':lane['errors'],'normal_turns':lane['normal_turns'],'max_sender_scheduling_late_ms':lane['max_scheduling_late_ms']})
 return {'mode':mode,'status':r['status'],'lanes':lanes,'both_connected_before_source':all(any(s['state']=='connected'and s['at']<r['source_origin']for s in l['states'])for l in r['lanes']),'all_segments_labeled':all(l['binding_evaluated']for l in lanes),'scope':'shared utterance lexical labels only; not independent word timestamps, subjective usability or long-duration guarantee'}
reports=[inspect(mode)for mode in ['natural','rapid','guarded']]
checks={}
for report in reports:
 raw=json.loads((ROOT/f"results/two-connections-{report['mode']}.json").read_text())
 checks[report['mode']]={'two_peers_connected':report['both_connected_before_source']and len(raw['lanes'])==2,'complete':report['status']=='complete','all_segment_samples_sent_exactly':all(l['sent_segments'].get(seg['id'],{}).get('samples')==seg['end_sample']-seg['start_sample']for seg in raw['segments']for l in raw['lanes']if l['connection']==seg['connection']),'no_service_errors':all(not l['errors']for l in raw['lanes']),'no_normal_turns':all(l['normal_turns']==0 for l in raw['lanes'])}
r={'evidence_valid':all(all(v.values())for v in checks.values()),'checks':checks,'reports':reports,'quiet_guard_seconds':1,'dedicated_asr_completion':False,'rapid_unresolved_B_retained':not reports[1]['all_segments_labeled'],'guarded_unresolved_B_retained':not reports[2]['all_segments_labeled']}
(ROOT/'results/two-connections-validation.json').write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n');print(json.dumps(r,ensure_ascii=False,indent=2));assert r['evidence_valid']
