#!/usr/bin/env python3
"""Validate actual retained cross-platform measurements, not predicted results."""
import json
from pathlib import Path
root=Path(__file__).resolve().parent.parent
for name in ['macos','windows','android','ios','web']:
 r=json.loads((root/f'results/report-{name}.json').read_text());assert r['ok'],name
 cases={c['case']:c for c in r['cases']}
 for key in ['60','600','slow','restart']:
  c=cases[key];duration=c['config']['duration_s'];s=c['stream']
  assert c['ok'] and c['audio']['samples']==duration*16000,(name,key)
  assert c['images']['count']==duration and len(c['images']['last'])<=8,(name,key)
  assert c['audio']['vad_positive']=={'60':709,'600':7002,'slow':709,'restart':79}[key],(name,key)
  assert c['max_pending_analysis_calls']==1,(name,key)
  assert s['first_pcm_ms']<s['elapsed_ms'] and s['first_image_ms']<s['elapsed_ms']
  if name=='web':
   assert s['first_output_read_bytes']<s['input_bytes']
   assert s['max_pending_analysis_calls']==1
  else:assert s['first_pcm_before_producer_done']
 c=cases['cancel'];assert c['ok'] and c['stream']['cancelled'];assert 5*16000<=c['audio']['samples']<6*16000
 assert cases['restart']['ok']
print('Five platforms: exact PCM length, matching VAD decisions, bounded result retention, early delivery, cancellation and restart passed.')
