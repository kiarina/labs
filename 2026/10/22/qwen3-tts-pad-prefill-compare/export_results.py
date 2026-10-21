"""Publish metrics while retaining unexpected/private-reference ASR only locally."""
import argparse,difflib,hashlib,json,shutil
from pathlib import Path
from evaluate import normalize

p=argparse.ArgumentParser();p.add_argument('--private-transcript-file',required=True);args=p.parse_args()
reference=normalize(Path(args.private_transcript_file).read_text());withheld=0;total=0
for name,source in [('pilot-v0','output-pilot'),('restart-v0','output-restart'),('guarded-pilot','output-guarded'),('80ms','output-main'),('40ms','output-fast')]:
 src=Path(source);dest=Path('results')/name;dest.mkdir(parents=True,exist_ok=True)
 rows=json.loads((src/'results.json').read_text());total+=len(rows)
 targets={f"{r['mode']}-{r['case']}-{r['schedule']}-{r['seed']}.wav":r['text'] for r in rows}
 for file in ['environment.json','results.json','listening.csv','wavlm-evaluation.json']:
  if (src/file).exists():shutil.copyfile(src/file,dest/file)
 ev=json.loads((src/'evaluation.json').read_text())
 for score in ev['scores']:
  raw=score.get('asr')
  if not isinstance(raw,str):continue
  text=normalize(raw);target=normalize(targets[score['file']])
  match=difflib.SequenceMatcher(None,reference,text,autojunk=False).find_longest_match()
  overlap=reference[match.a:match.a+match.size]
  score['normalized_asr_chars']=len(text)
  score['maximum_reference_overlap_chars']=match.size
  if raw and ((match.size>=8 and overlap not in target) or (score['file'].startswith('pad_') and score.get('cer',0)>0)):
   score['asr_sha256']=hashlib.sha256(raw.encode()).hexdigest()
   score['asr']='[nonmatching transcript withheld; raw local output retained]'
   score['asr_withheld']=True;withheld+=1
 (dest/'evaluation.json').write_text(json.dumps(ev,ensure_ascii=False,indent=2))
Path('results/export.json').write_text(json.dumps({'measured_rows':total,'withheld_asr_strings':withheld,'policy':'Unexpected PAD ASR and non-target reference overlaps are retained in ignored outputs, not published. Metrics/failures are not removed.'},indent=2))
print('exported',total,'rows; withheld',withheld,'ASR strings')
