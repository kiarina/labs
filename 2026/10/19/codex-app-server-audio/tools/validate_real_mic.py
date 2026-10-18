#!/usr/bin/env python3
"""Evaluate a completed real-mic run; never reads or requires spoken text."""
import json,math
from pathlib import Path
root=Path(__file__).resolve().parent.parent
r=json.loads((root/'results/real-microphone-listen-only.json').read_text());s=r['summary'];b=s['browser'];times=r['transcript_delta_times_seconds'];bins=sorted(set(min(4,int(t//60))for t in times))
checks={
 'five_minute_completed':r['end_reason']=='timeout'and 295<=s['elapsed_seconds']<=315,
 'chatgpt_only':r['auth_type']=='chatgpt'and not r['api_key_fallback']and not r['proxy_used'],
 'real_builtin_input':b.get('builtin_microphone')is True and b.get('input_active_seconds',0)>=60,
 'input_transcripts_continue':len(bins)>=4 and times and max(times)>=240,
 'no_assistant_transcript':s['assistant_deltas']==0,
 'no_nonzero_output':b.get('output_samples',0)>0 and b.get('output_nonzero_samples')==0 and b.get('output_peak')==0,
 'live_measurement_and_transport':all(b.get(k)is True for k in ['peer_connected','data_channel_open','meter_running','track_live'])and b.get('packets_sent',0)>0 and b.get('packets_received',0)>0,
 'no_runtime_errors_or_backing_turns':s['error_count']==0 and s['normal_turns']==0,
 'no_local_speech_content_saved':not r['raw_audio_saved']and not r['transcript_text_saved'],
}
verdict={'ok':all(checks.values()),'checks':checks,'elapsed_seconds':s['elapsed_seconds'],'transcript_deltas':s['transcript_deltas'],'transcript_characters':s['transcript_characters'],'transcript_minute_bins':bins,'last_transcript_at_seconds':s['last_transcript_at_seconds'],'input_active_seconds':b.get('input_active_seconds'),'output_nonzero_samples':b.get('output_nonzero_samples'),'scope':'One real microphone, one human, five minutes; prompt compliance, not an ASR-only API guarantee'}
print(json.dumps(verdict,indent=2));raise SystemExit(0 if verdict['ok']else 1)
