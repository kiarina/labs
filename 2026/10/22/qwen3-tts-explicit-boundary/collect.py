"""Collect disjoint runs on the same backend without repeating inference."""
import argparse,json,shutil
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--folders',nargs='+',required=True);p.add_argument('--output',required=True);args=p.parse_args()
out=Path(args.output);out.mkdir(parents=True,exist_ok=True);rows=[];scores=[];envs=[];seen=set();base=None;evbase=None
for folder in args.folders:
 root=Path(folder);env=json.loads((root/'environment.json').read_text());envs.append({'folder':folder,**env})
 identity={k:env[k] for k in ['model','revision','dtype','system','reference_sha256','transcript_sha256','versions']}
 if base is None:base=identity
 else:assert base==identity,'Do not merge incomparable runs'
 for r in json.loads((root/'results.json').read_text()):
  stem=f"{r['mode']}-{r['case']}-{r['schedule']}-{r['seed']}";assert stem not in seen;seen.add(stem)
  rows.append({**r,'source_run':folder})
  for ext in ['.wav','.json']:
   if (root/(stem+ext)).exists():shutil.copyfile(root/(stem+ext),out/(stem+ext))
 ev=json.loads((root/'evaluation.json').read_text());scores+=ev['scores']
 if evbase is None:evbase={k:v for k,v in ev.items() if k!='scores'}
(out/'environment.json').write_text(json.dumps({'identity':base,'runs':envs},indent=2))
(out/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
(out/'evaluation.json').write_text(json.dumps({**evbase,'scores':scores},ensure_ascii=False,indent=2))
print('collected',len(rows),'unique rows')
