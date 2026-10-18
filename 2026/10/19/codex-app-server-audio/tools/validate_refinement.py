#!/usr/bin/env python3
"""Validate actual observations without treating partial correspondence as success."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1];load=lambda n:json.loads((root/'results'/n).read_text())
speaker=load('speaker-refinement-offline.json');controls=load('refinement-clock-controls.json');first=load('refined-asr-fixture.json');final=load('refined-asr-fixture-final.json');mapping=load('refinement-runtime-binding.json');second=load('refinement-final-binding.json')
def partition_matches(truth,labels):
 if any(x is None for x in labels):return False
 return all((a==b)==(x==y)for a,x in zip(truth,labels)for b,y in zip(truth,labels))
checks={
 'matching_threshold_unchanged':speaker['matching_threshold']==.45,
 'speaker_scenario_counts':[s['refined_clusters']for s in speaker['scenarios']]==[2,2,1,3],
 'speaker_roles_consistent_up_to_id_permutation':all(partition_matches(s['truth_roles'],s['refined_labels'])for s in speaker['scenarios']),
 'baseline_failures_retained':speaker['scenarios'][0]['baseline_clusters']==3 and speaker['scenarios'][3]['baseline_clusters']==4,
 'clock_controls_pass_including_clipped_prefix_and_rejection':controls['ok']and len(controls['cases'])==6,
 'both_live_runs_keep_two_clusters':first['speaker_clusters']==final['speaker_clusters']==2,
 'both_live_runs_stream_captions_during_capture':all(r['connections']==1 and r['fragment_count']==r['fragments_during_capture']>0 for r in [first,final]),
 'no_audio_response_or_input_loss_in_live_cases':all(r['output_nonzero_samples']==r['assistant_text_chars']==r['audio_dropped_bytes']==r['scheduled_late_frames']==r['unexpected_delegations']==0 for r in [first,final]),
 'waveform_anchors_observed':len(first['clock_evidence']['anchors'])>=2 and len(final['clock_evidence']['anchors'])>=2,
 'holdout_clock_interpolation_improves_internal_fit':mapping['held_out_interpolation_error_ms_max']<30<mapping['constant_offset_error_ms_max'],
 'global_clock_failure_retained':not final['clock_evidence']['alignment']['valid']and all(f['binding']=='clock_pending'for f in final['fragments']),
 'boundary_tradeoff_not_hidden':next(v for v in mapping['sweep']if v['guard_seconds']==1)['held']==33 and next(v for v in mapping['sweep']if v['guard_seconds']==1)['wrong']==0,
 'second_run_gaps_not_interpolated':next(v for v in second['sweep']if v['guard_seconds']==1)['clock_held']==15,
 'runtime_mapper_replayed':mapping['uses_runtime_mapper']and second['uses_runtime_mapper'],
}
report={'ok':all(checks.values()),'checks':checks,'speaker_improvement_observed':True,'clock_alignment':'waveform based; piecewise supported regions, not a universal exact clock','word_correspondence_complete':False,'one_second_guard_cases':[{'fragments':len(r['fragments']),**{k:v for k,v in next(s for s in m['sweep']if s['guard_seconds']==1).items()if k!='assignments'}}for r,m in [(first,mapping),(final,second)]],'no_new_human_microphone_trial':True,'prototype_changed':False,'live_runs_repeated_by_validator':False}
print(json.dumps(report,ensure_ascii=False,indent=2));raise SystemExit(0 if report['ok']else 1)
