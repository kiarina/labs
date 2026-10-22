"""Second independent speaker diagnostic, CPU only, fixed WavLM-Large+ECAPA int8."""
import argparse,hashlib,json
from pathlib import Path
import numpy as np
import onnxruntime as ort
from evaluate import audio

EXPECTED='ccd31b45eb2162937b94921d6e64fdd2cf5bf77193ad6f738e85f06a914a95ca'
p=argparse.ArgumentParser();p.add_argument('--model',required=True);p.add_argument('--reference',required=True);p.add_argument('--output',default='output-main');args=p.parse_args()
assert hashlib.sha256(Path(args.model).read_bytes()).hexdigest()==EXPECTED
options=ort.SessionOptions();options.intra_op_num_threads=4;options.inter_op_num_threads=1
s=ort.InferenceSession(args.model,sess_options=options,providers=['CPUExecutionProvider'])
def vector(a):
 v=np.asarray(s.run(['embedding'],{'wav':a.reshape(1,-1)})[0],dtype=np.float32).reshape(-1)
 assert v.shape==(256,) and np.isfinite(v).all() and np.linalg.norm(v)>0
 return v/np.linalg.norm(v)
ref=vector(audio(args.reference));out=Path(args.output);rows=json.loads((out/'results.json').read_text());scores=[];cache={}
reference_sha=hashlib.sha256(Path(args.reference).read_bytes()).hexdigest()
previous=out/'wavlm-evaluation.json'
if previous.exists():
 old=json.loads(previous.read_text())
 if old.get('reference_sha256')==reference_sha:cache={x['pcm_16k_sha256']:x['cosine'] for x in old['scores']}
for row in rows:
 if row['schedule']!='chars':continue
 file=out/f"{row['mode']}-{row['case']}-{row['schedule']}-{row['seed']}.wav"
 a=audio(file);digest=hashlib.sha256(a.tobytes()).hexdigest()
 if digest not in cache:cache[digest]=float(np.dot(ref,vector(a)))
 score={'file':file.name,'cosine':cache[digest],'pcm_16k_sha256':digest};scores.append(score);print(json.dumps(score),flush=True)
 (out/'wavlm-evaluation.json').write_text(json.dumps({'reference_sha256':reference_sha,'model':'kiarina/MeanVC2-ONNX speaker/speaker.int8.onnx','revision':'2db97430c6e315a819daa30e255e14615205a3d1','sha256':EXPECTED,'onnxruntime':ort.__version__,'reference_self_cos':float(np.dot(ref,ref)),'scores':scores},indent=2))
