"""Private ASR for decoder ablation; export only counts and hashes of prefixes."""
import argparse,difflib,hashlib,json
from pathlib import Path
import mlx_whisper
from huggingface_hub import snapshot_download
from evaluate import audio,normalize,ASR,ASR_REV

p=argparse.ArgumentParser();p.add_argument('--output',default='output-decoder-tail');p.add_argument('--transcript-file',required=True);p.add_argument('--reuse');args=p.parse_args()
root=Path(args.output);report=json.loads((root/'decode.json').read_text());reference=normalize(Path(args.transcript_file).read_text());target=normalize(report['target_text']);cache={}
if args.reuse:
 for row in json.loads(Path(args.reuse).read_text())['scores']:
  if isinstance(row.get('asr'),str) and not row.get('asr_withheld',False):cache[row['pcm_16k_sha256']]=row['asr']
model=snapshot_download(ASR,revision=ASR_REV);raw=[];summaries=[]
for row in report['rows']:
 a=audio(root/f"{row['mode']}.wav");digest=hashlib.sha256(a.tobytes()).hexdigest()
 if digest not in cache:cache[digest]=mlx_whisper.transcribe(a,path_or_hf_repo=model,language='ja',temperature=0.)['text']
 text=cache[digest];n=normalize(text);anchor=n.find(target[:12]);prefix=n[:anchor] if anchor>=0 else n
 match=difflib.SequenceMatcher(None,reference,prefix,autojunk=False).find_longest_match()
 raw.append({'mode':row['mode'],'asr':text})
 summary={'mode':row['mode'],'target_prefix_found':anchor>=0,'chars_before_target':anchor if anchor>=0 else None,'reference_overlap_before_target':match.size,'asr_sha256':hashlib.sha256(text.encode()).hexdigest(),'pcm_16k_sha256':digest}
 summaries.append(summary);print(json.dumps(summary),flush=True)
(root/'asr-private.json').write_text(json.dumps(raw,ensure_ascii=False,indent=2))
(root/'asr-summary.json').write_text(json.dumps({'asr_model':ASR,'asr_revision':ASR_REV,'rows':summaries},indent=2))
