#!/usr/bin/env python3
"""Offline character alignment/latency comparison on shared fixture only."""
import json,statistics,unicodedata
from pathlib import Path
root=Path(__file__).resolve().parents[1];refs=json.loads((root/'fixtures/segments.json').read_text())
def norm(t):return ''.join(c for c in unicodedata.normalize('NFKC',t).lower()if not c.isspace()and not unicodedata.category(c).startswith('P'))
reference=''.join(norm(s['reference'])for s in refs);roles=[]
for i,seg in enumerate(refs):roles.extend([i]*len(norm(seg['reference'])))
def align(a,b):
 d=[list(range(len(b)+1))]+[[i]+[0]*len(b)for i in range(1,len(a)+1)]
 for i in range(1,len(a)+1):
  for j in range(1,len(b)+1):d[i][j]=min(d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+(a[i-1]!=b[j-1]))
 i,j=len(a),len(b);pairs=[];deleted=inserted=substituted=0
 while i or j:
  if i and j and d[i][j]==d[i-1][j-1]+(a[i-1]!=b[j-1]):pairs.append((i-1,j-1));substituted+=a[i-1]!=b[j-1];i-=1;j-=1
  elif i and d[i][j]==d[i-1][j]+1:deleted+=1;i-=1
  else:inserted+=1;j-=1
 return d[-1][-1],pairs,deleted,inserted,substituted
reports={};checks={}
for mode in ['baseline','streaming']:
 r=json.loads((root/f'results/online-{mode}.json').read_text());rows=r['rows'];hyp='';row_for=[]
 for i,row in enumerate(rows):s=norm(row['text']);hyp+=s;row_for.extend([i]*len(s))
 edits,pairs,deletions,insertions,substitutions=align(reference,hyp);arrivals=[[]for _ in refs];row_roles=[set()for _ in rows]
 for a,b in pairs:
  utterance=roles[a];row=rows[row_for[b]];row_roles[row_for[b]].add(utterance%2);arrivals[utterance].append(row['end']*1000+row['end_to_text_ms'])
 latencies=[{'utterance':i+1,'source_end':seg['end'],'last_aligned_character_latency_ms':max(arrivals[i])-seg['end']*1000 if arrivals[i]else None,'aligned_characters':len(arrivals[i])}for i,seg in enumerate(refs)]
 ms=[v['last_aligned_character_latency_ms']for v in latencies if v['last_aligned_character_latency_ms']is not None]
 inferred=[row['end']for row in rows if row['reason']=='scd_change']
 id_roles={}
 for row,expected in zip(rows,row_roles):
  if row['speaker_id']!='話者未確定':id_roles.setdefault(row['speaker_id'],set()).update(expected)
 identity_consistent=all(len(v)==1 for v in id_roles.values())
 reports[mode]={'segments':len(rows),'cer':edits/len(reference),'edits':edits,'reference_characters':len(reference),'deleted_characters':deletions,'inserted_characters':insertions,'substituted_characters':substitutions,'utterances':latencies,'utterance_latency_median_ms':statistics.median(ms),'utterance_latency_max_ms':max(ms),'scd_changes':inferred,'mixed_expected_roles_by_lexical_alignment':[i+1 for i,v in enumerate(row_roles)if len(v)>1],'asr_ms_median':statistics.median(x['asr_ms']for x in rows),'online_scd_inferences':r['scd_inferences'],'scd_inference_ms_median':statistics.median(r['scd_inference_ms'])if r['scd_inference_ms']else None,'speaker_candidates':r['speakers'],'unknown_rows':sum(row['speaker_id']=='話者未確定'for row in rows),'known_ids_consistent_up_to_permutation':identity_consistent,'id_expected_role_sets':{k:sorted(v)for k,v in id_roles.items()},'confirmed_boundary_wait_ms':[row['confirmed_ms']-row['end']*1000 for row in rows if row['reason']=='scd_change']}
 checks[mode]={'no_errors':not r['errors'],'no_microphone':not r['microphone_used'],'all_rows_nonempty':all(row['characters']>0 and row['status']=='確定'for row in rows),'request_ids_unique':len({row['id']for row in rows})==len(rows),'audio_ranges_not_duplicated':all(a['end']<=b['start']+.0001 for a,b in zip(rows,rows[1:])),'six_utterances_aligned':len(ms)==6}
control=json.loads((root/'results/online-one-speaker.json').read_text())
control_text=''.join(norm(row['text'])for row in control['rows'])
control_reference=''.join(norm(refs[i]['reference'])for i in [0,2,4])
control_edits,*_=align(control_reference,control_text)
control_summary={'segments':len(control['rows']),'scd_change_cuts':sum(row['reason']=='scd_change'for row in control['rows']),'speaker_candidates':control['speakers'],'cer':control_edits/len(control_reference),'reasons':[row['reason']for row in control['rows']],'physical_microphone':control['microphone_used']}
checks['one_speaker']={'no_spurious_scd_cuts':control_summary['scd_change_cuts']==0,'one_candidate':control['speakers']==1,'no_errors':not control['errors'],'nonempty':all(row['characters']>0 for row in control['rows']),'no_microphone':not control['microphone_used']}
r={'evidence_valid':all(all(x.values())for x in checks.values()),'checks':checks,'reports':reports,'one_speaker_control':control_summary,'alignment_scope':'whole-transcript Levenshtein alignment to six shared utterances; not word timing truth; latency of available aligned text, report CER alongside','general_accuracy_verified':False}
(root/'results/online-comparison.json').write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n');print(json.dumps(reports,ensure_ascii=False,indent=2));assert r['evidence_valid']
