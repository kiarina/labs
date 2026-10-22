"""Export all metrics; keep unexpected/private ASR text in ignored outputs."""
import argparse,difflib,hashlib,json,shutil
from pathlib import Path
from evaluate import normalize

p=argparse.ArgumentParser();p.add_argument('--reference-transcript',required=True);p.add_argument('--folders',nargs='+',default=['output-pilot','output-validation']);args=p.parse_args()
reference=normalize(Path(args.reference_transcript).read_text());total=0;withheld=0
for folder in args.folders:
 src=Path(folder)
 if not (src/'results.json').exists():continue
 dest=Path('results')/src.name.removeprefix('output-');dest.mkdir(parents=True,exist_ok=True)
 rows=json.loads((src/'results.json').read_text());total+=len(rows)
 targets={f"{r['mode']}-{r['case']}-{r['schedule']}-{r['seed']}.wav":r for r in rows}
 for name in ['environment.json','results.json','listening.csv','wavlm-evaluation.json']:
  if (src/name).exists():shutil.copyfile(src/name,dest/name)
 if not (src/'evaluation.json').exists():continue
 ev=json.loads((src/'evaluation.json').read_text())
 for score in ev['scores']:
  raw=score.get('asr')
  if not isinstance(raw,str):continue
  hyp=normalize(raw);r=targets[score['file']];target=normalize(r['text'])
  match=difflib.SequenceMatcher(None,reference,hyp,autojunk=False).find_longest_match()
  score['normalized_asr_chars']=len(hyp);score['maximum_reference_overlap_chars']=match.size
  if raw and ((match.size>=8 and reference[match.a:match.a+match.size] not in target) or (r['mode']!='icl' and score.get('cer',0)>0)):
   score['asr_sha256']=hashlib.sha256(raw.encode()).hexdigest();score['asr']='[nonmatching transcript withheld; raw local output retained]';score['asr_withheld']=True;withheld+=1
 (dest/'evaluation.json').write_text(json.dumps(ev,ensure_ascii=False,indent=2))
Path('results/export.json').write_text(json.dumps({'rows':total,'withheld_asr_strings':withheld,'policy':'Unexpected transcript strings are withheld; metrics and failures are kept.'},indent=2))
print('exported',total,'rows;',withheld,'ASR strings withheld')
