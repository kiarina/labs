#!/usr/bin/env python3
"""Offline validation of the full app's shared fixture run; no audio capture."""
import json,statistics
from pathlib import Path
root=Path(__file__).resolve().parents[1];r=json.loads((root/'results/app-fixture.json').read_text());rows=r['rows']
checks={'no_physical_microphone':r['microphone_used']is False,'shared_pcm_callbacks':r['callbacks']>0,'all_rows_recognized':bool(rows)and all(x['status']=='確定'and x['characters']>0 for x in rows),'unique_request_ids':len({x['id']for x in rows})==len(rows),'ordered_scd_segments':all(a['end']<=b['start']+.001 for a,b in zip(rows,rows[1:])),'no_pipeline_errors':not r['errors'],'short_speaker_unknown_retained':any(x['speaker_id']=='話者未確定'for x in rows),'two_candidate_clusters':r['speakers']==2,'no_saved_text_or_audio':all('text'not in x and 'audio'not in x and 'embedding'not in x for x in rows)}
out={'evidence_valid':all(checks.values()),'checks':checks,'segments':len(rows),'asr_ms_median':statistics.median(x['asr_ms']for x in rows),'asr_ms_max':max(x['asr_ms']for x in rows),'end_to_text_ms_min':min(x['end_to_text_ms']for x in rows),'end_to_text_ms_max':max(x['end_to_text_ms']for x in rows),'speaker_accuracy_verified':False,'physical_microphone_trial_done':False,'scope':'full native app shared fixture; VAD/SCD/ECAPA/native ASR, no human speech'}
(root/'results/app-validation.json').write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n');print(json.dumps(out,ensure_ascii=False,indent=2));assert out['evidence_valid']
