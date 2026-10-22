"""Independent ECAPA speaker diagnostic and fixed Whisper reading diagnostic."""
import argparse
import difflib
import hashlib
import importlib.metadata
import platform
import json
import re
import subprocess
import unicodedata
from pathlib import Path

import numpy as np
import onnxruntime as ort

ECAPA_SHA='245eb5995cfffd74494862dee33da2b00c1c2579eb0c6703847784e9901ed458'
ASR='mlx-community/whisper-large-v3-turbo'
ASR_REV='a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb'

def audio(path):
 return np.frombuffer(subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-ac','1','-ar','16000','-f','f32le','pipe:1']),dtype='<f4').copy()
def normalize(text):
 return ''.join(c for c in unicodedata.normalize('NFKC',text).lower() if not unicodedata.category(c).startswith(('P','Z','S')) and not c.isspace())
def distance(a,b):
 row=list(range(len(b)+1))
 for i,x in enumerate(a,1):
  nextrow=[i]
  for j,y in enumerate(b,1):nextrow.append(min(nextrow[-1]+1,row[j]+1,row[j-1]+(x!=y)))
  row=nextrow
 return row[-1]

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',default='output');p.add_argument('--reference',required=True)
 p.add_argument('--ecapa',default=str(Path.home()/'.cache/kiarina-agi-audio/models/ecapa-tdnn-onnx/ecapa_tdnn.onnx'));p.add_argument('--asr',action='store_true');p.add_argument('--transcript-file');p.add_argument('--reuse');args=p.parse_args()
 out=Path(args.output);path=Path(args.ecapa)
 if not path.exists():
  from huggingface_hub import hf_hub_download
  path=Path(hf_hub_download('pranjal-pravesh/ecapa_tdnn_onnx',filename='ecapa_tdnn.onnx',revision='04c3ffe4fd00b3b7853fd57db44e2e531d4817f2'))
 assert hashlib.sha256(path.read_bytes()).hexdigest()==ECAPA_SHA
 options=ort.SessionOptions();options.intra_op_num_threads=4;options.inter_op_num_threads=1
 session=ort.InferenceSession(str(path),sess_options=options,providers=['CPUExecutionProvider']);info=session.get_inputs()[0]
 def embed(a):
  shape={1:(-1,),2:(1,-1),3:(1,1,-1)}[len(info.shape)];v=np.asarray(session.run(None,{info.name:a.reshape(shape)})[0],dtype=np.float32).reshape(-1)
  assert v.shape==(192,) and np.isfinite(v).all();return v/np.linalg.norm(v)
 reference_text=normalize(Path(args.transcript_file).read_text()) if args.transcript_file else None
 ref=embed(audio(args.reference));rows=json.loads((out/'results.json').read_text());cache={};scores=[]
 if args.reuse:
  for item in json.loads(Path(args.reuse).read_text())['scores']:
   if 'asr' in item:cache[item['pcm_16k_sha256']]=item['asr']
 if args.asr:
  import mlx_whisper
  from huggingface_hub import snapshot_download
  asrpath=snapshot_download(ASR,revision=ASR_REV)
 for row in rows:
  name=f"{row['mode']}-{row['case']}-{row['schedule']}-{row['seed']}"
  file=out/f'{name}.wav'
  if not file.exists():continue
  a=audio(file);digest=hashlib.sha256(a.tobytes()).hexdigest();score={'file':file.name,'ecapa_cos':float(np.dot(ref,embed(a))),'pcm_16k_sha256':digest}
  if args.asr:
   if digest not in cache:cache[digest]=mlx_whisper.transcribe(a,path_or_hf_repo=asrpath,language='ja',temperature=0.)['text']
   target=normalize(row['text']);hyp=normalize(cache[digest]);score.update(asr=cache[digest],cer=distance(target,hyp)/len(target),target_chars=len(target))
   # Leak check (same rule as the PAD-prefill lab's decoder-tail diagnosis):
   # anchor on the target's first 12 normalized chars, then measure the longest
   # run of the reference transcript inside whatever ASR heard before it.
   anchor=hyp.find(target[:12]);prefix=hyp[:anchor] if anchor>=0 else hyp
   overlap=difflib.SequenceMatcher(None,reference_text,prefix,autojunk=False).find_longest_match().size if reference_text else None
   score.update(target_prefix_found=anchor>=0,chars_before_target=anchor if anchor>=0 else None,reference_overlap_before_target=overlap)
  scores.append(score);print(json.dumps(score,ensure_ascii=False),flush=True)
  (out/'evaluation.json').write_text(json.dumps({'python':platform.python_version(),'onnxruntime':importlib.metadata.version('onnxruntime'),'numpy':np.__version__,'ecapa_sha256':ECAPA_SHA,'reference_self_cos':float(np.dot(ref,ref)),'asr':ASR if args.asr else None,'asr_revision':ASR_REV if args.asr else None,'scores':scores},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
