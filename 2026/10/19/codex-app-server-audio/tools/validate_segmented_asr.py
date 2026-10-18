#!/usr/bin/env python3
"""Validate retained observations, including the negative silent-ASR result."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1];cases=[]
for name in ['first','strong']:
 r=json.loads((root/f'results/segmented-asr-shared-{name}.json').read_text());rows=r['segments'];ids=[v['segment_id']for v in rows]
 checks={'six_nonempty_transcripts':len(rows)==6 and all(v['text'].strip()for v in rows),'unique_binding':len(set(ids))==6 and all(v['wrong_segment_events']==0 for v in rows),'speaker_reentry':[v['speaker_id']for v in rows]==['speaker-1','speaker-2']*3,'auth_chatgpt_only':all(v['auth']=='chatgpt'for v in rows),'no_backing_turns':all(v['unexpected_turns']==0 for v in rows),'silence_filtered':sum(v['sent_audio_seconds']for v in rows)<r['input_seconds']-5,'ordered_source_ranges':all(a['end']<=b['start']+.00001 for a,b in zip(rows,rows[1:])),'no_queue_loss':not r['errors']and r['dropped_voices']==0}
 spoken=[v['segment_id']for v in rows if v['output_nonzero_samples']>0 or v['assistant_text_chars']>0]
 # The failure is part of the retained evidence, not silently upgraded to success.
 checks['observed_speech_failure_retained']=len(spoken)==2
 cases.append({'case':name,'evidence_valid':all(checks.values()),'checks':checks,'mapping_observed':checks['unique_binding']and checks['speaker_reentry'],'strict_silent_asr':not spoken,'spoken_segments':spoken,'server_done_segments':sum(v['server_done']for v in rows),'provisional_segments':sum(not v['server_done']for v in rows),'sent_seconds':sum(v['sent_audio_seconds']for v in rows),'input_seconds':r['input_seconds']})
report={'ok':all(x['evidence_valid']for x in cases),'cases':cases,'conclusion':'Per-segment identity binding works in this fixture; prompt-only silent ASR failed in both runs; quiescence is provisional, not a server completion guarantee','live_runs_repeated':False}
print(json.dumps(report,ensure_ascii=False,indent=2));raise SystemExit(0 if report['ok']else 1)
