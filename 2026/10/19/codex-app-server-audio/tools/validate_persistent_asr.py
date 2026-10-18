#!/usr/bin/env python3
"""Offline checks of the actual timing path, transport, and retained limitations."""
import json,statistics
from pathlib import Path
root=Path(__file__).resolve().parents[1]
load=lambda n:json.loads((root/'results'/n).read_text())
p=load('persistent-timing-probe.json');bad=load('persistent-asr-fixture-first.json');r=load('persistent-asr-fixture-native.json');fs=r['fragments'];ledger=r['send_ledger'];offset=r['alignment_offset_ms']
checks={
 'chatgpt_legacy_timestamps_observed':p['auth']=='chatgpt'and not p['api_key_fallback']and all({'start_ms','end_ms'}<=set(e['numbers'])for e in p['events']if e['type']=='input_transcript.added'),
 'first_failed_timer_run_retained':bad['pump_skipped_frames']>0 and any(f.get('binding')=='no_sent_audio_overlap'for f in bad['fragments']),
 'persistent_single_connection':r['connections']==1,
 'native_clock_has_no_late_or_dropped_frames':r['send_clock']=='native_scheduled'and r['scheduled_late_frames']==r['scheduled_underflows']==r['pump_skipped_frames']==r['audio_dropped_bytes']==0,
 'all_fragments_visible_while_capturing':r['fragment_count']==r['fragments_during_capture']>0,
 'silence_suppressed':0<r['sent_source_seconds']<r['captured_seconds'],
 'no_audio_response_in_this_run':r['assistant_text_chars']==r['output_nonzero_samples']==r['unexpected_delegations']==0,
 'all_intervals_have_timestamps':all(isinstance(f.get('start_ms'),(int,float))and f['end_ms']>=f['start_ms']for f in fs),
 'native_source_ledger_is_linear':all(abs(v['device_ms']-v['source_ms']-r['device_origin_ms'])<.001 for v in ledger),
 'no_runtime_errors':not r['errors'],
}
# Numeric interval reconstruction also works if delivery happens later; it
# deliberately does not consult received_ms or current/last speaker state.
def source_interval(f):
 hits=[v for v in ledger if v['sent']and v['device_ms']<f['end_ms']+offset and v['device_ms']+10>f['start_ms']+offset]
 return (hits[0]['source_ms']/1000,(hits[-1]['source_ms']+10)/1000)if hits else None
checks['recorded_source_intervals_reconstruct']=all(source_interval(f)==(f.get('source_start'),f.get('source_end'))for f in fs)
checks['delayed_delivery_does_not_move_source_interval']=all(source_interval(f)==source_interval({**f,'received_ms':f['received_ms']+5000})for f in fs)
anchors={'もし':'speaker-1','改札':'speaker-2','電車':'speaker-1','カフェ':'speaker-2','寒い':'speaker-1','マフ':'speaker-2'}
anchor_results=[{'text_marker':key,'expected_speaker':expected,'observed_speakers':[f.get('speaker_id')for f in fs if key in f['text']],'matches':any(f.get('speaker_id')==expected for f in fs if key in f['text'])}for key,expected in anchors.items()]
checks['speaker_reentry_failure_not_hidden']=r['speaker_clusters']==3 and sum(a['matches']for a in anchor_results)==4
real=load('persistent-asr-real-mic.json');rf=real['fragments']
real_checks={'one_connection':real['connections']==1,'real_record_capture':real['physical_microphone_used'] and not real['synthetic'] and real['capture_callbacks']>0,'no_human_transcript_or_embedding_saved':all('text'not in f and 'embedding'not in f for f in rf),'visible_during_capture':real['fragments_during_capture']>0,'no_response_this_run':real['assistant_text_chars']==real['output_nonzero_samples']==real['unexpected_delegations']==0,'one_speaker_cluster':real['speaker_clusters']==1,'one_late_frame_retained':real['scheduled_late_frames']==1 and real['audio_dropped_bytes']==960,'uncertain_fragments_not_forced':sum(f.get('binding')=='no_sent_audio_overlap'for f in rf)==3,'no_runtime_errors':not real['errors']}
real_summary={'evidence_valid':all(real_checks.values()),'checks':real_checks,'fragment_count':len(rf),'assigned_provisionally':sum(f.get('speaker_id')is not None for f in rf),'held':sum(f.get('speaker_id')is None for f in rf),'estimated_latency_ms_median':real['latency_ms_median'],'estimated_latency_ms_p95':real['latency_ms_p95'],'human_practicality':'user confirmed practical speed and content for one speaker / 30 seconds'}
report={'ok':all(checks.values()) and real_summary['evidence_valid'],'checks':checks,'real_microphone':real_summary,'latency_scope':'estimated source intervals: first-VAD/first-transcript clock-origin assumption, not exact word timing','estimated_display_latency_ms':{'median':r['latency_ms_median'],'p95':r['latency_ms_p95']},'first_caption_after_vad_start_ms':r['first_delta_ms']-r['first_vad_ms'],'gate_processing_ms':{'median':statistics.median(r['gate_ms']),'max':max(r['gate_ms'])},'reference_anchors':anchor_results,'speaker_identity_complete':False,'clock_alignment_exact':False,'human_practicality':'user confirmed practical speed and content for one speaker / 30 seconds','live_runs_repeated':False}
print(json.dumps(report,ensure_ascii=False,indent=2));raise SystemExit(0 if report['ok']else 1)
