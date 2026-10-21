"""Isolated same-reference conditioning comparison; no production imports."""
import argparse
import hashlib
import importlib.metadata
import json
import platform
import threading
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from huggingface_hub import snapshot_download
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import load_audio

from live import TextSource, generate_live, prepare_clone, prepare_xvector

MODEL='mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16'
REV='a6eb4f68e4b056f1215157bb696209bc82a6db48'
TEXTS={
 'short':'こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？',
 'long':'うん、今ここまでちゃんと声を出してくれただけで十分だよ。無理しなくていいし、ゆっくりでいいからね。しんどい時は、しんどいって言っていいんだよ。今日もよく頑張ってるよ。そのままのあなたで大丈夫だからね。明日は少しだけ散歩をして、おいしいご飯を食べよう。',
}

def digest(b): return hashlib.sha256(b).hexdigest()
def vector(model,audio):
 return np.array(model.extract_speaker_embedding(mx.array(audio,dtype=mx.float32)).astype(mx.float32))[0]
def cosine(a,b): return float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)))

def run(model,prompt,reference_vector,text,mode,case,schedule,seed,interval,out):
 source=TextSource(model.tokenizer);events=[];start=time.perf_counter();chunks=[];failure=None;trace={}
 def now():return time.perf_counter()-start
 def feed():
  try:
   if schedule=='full':source.push(text)
   else:
    for ch in text:
     source.push(ch);events.append({'type':'append','t':now(),'chars':len(source.text)})
     time.sleep(interval)
   events.append({'type':'text.done','t':now()});source.close()
  except Exception as exc:
   events.append({'type':'producer_error','t':now(),'error':str(exc)});source.cancel()
 producer=threading.Thread(target=feed,daemon=True);producer.start();mx.random.seed(seed)
 try:
  for pcm in generate_live(model,prompt,source,temperature=.9,trace=trace):
   a=np.array(pcm,dtype=np.float32);chunks.append(a)
   events.append({'type':'pcm','t':now(),'samples':len(a),'chars':len(source.text)})
 except Exception as exc:
  failure=repr(exc);source.cancel()
 elapsed=now();producer.join(5)
 stem=f'{mode}-{case}-{schedule}-{seed}'
 result={'mode':mode,'case':case,'schedule':schedule,'seed':seed,'text':text,'interval_s':interval,'error':failure,'required_prefix_tokens':prompt.required_prefix_tokens,'total_s':elapsed,'stop':trace.get('stop')}
 if chunks:
  a=np.concatenate(chunks);sf.write(out/f'{stem}.wav',a,24000,subtype='FLOAT')
  arrivals=[x for x in events if x['type']=='pcm'];done=next((x['t'] for x in events if x['type']=='text.done'),None)
  deadline=arrivals[0]['t'];gap=0
  for event in arrivals:
   gap+=max(0,event['t']-deadline);deadline=max(deadline,event['t'])+event['samples']/24000
  rms=np.sqrt(np.mean(a[:len(a)//240*240].reshape(-1,240)**2,axis=1))
  active=np.flatnonzero(rms>.003);onset=int(active[0])*240 if len(active) else len(a)
  offset=0;onset_arrival=None
  for event in arrivals:
   if offset+event['samples']>onset:onset_arrival=event['t'];break
   offset+=event['samples']
  v=vector(model,a)
  result.update(first_pcm_s=arrivals[0]['t'],first_pcm_chars=arrivals[0]['chars'],text_done_s=done,
   before_done=done is not None and arrivals[0]['t']<done,onset_audio_s=onset/24000,onset_chunk_arrival_s=onset_arrival,
   audio_s=len(a)/24000,gap_s=gap,speaker_cos=cosine(v,reference_vector),pcm_sha256=digest(a.tobytes()),
   codes_sha256=digest(json.dumps(trace.get('codes')).encode()),frames=len(trace.get('codes',[])),finite=bool(np.isfinite(a).all()),
   peak=float(np.max(np.abs(a))),silent_frame_fraction=float(np.mean(rms<.003)))
 (out/f'{stem}.json').write_text(json.dumps({'result':result,'events':events,'trace':trace},ensure_ascii=False,indent=2))
 print(json.dumps(result,ensure_ascii=False),flush=True)
 return result

def main():
 p=argparse.ArgumentParser();p.add_argument('--reference',required=True);p.add_argument('--transcript-file',required=True)
 p.add_argument('--output',default='output');p.add_argument('--seeds',nargs='+',type=int,default=[42,43,44]);p.add_argument('--cases',nargs='+',default=['short','long']);p.add_argument('--schedules',nargs='+',default=['full','chars']);p.add_argument('--interval',type=float,default=.08)
 args=p.parse_args();out=Path(args.output);out.mkdir(parents=True,exist_ok=True)
 t=time.perf_counter();model=load_model(snapshot_download(MODEL,revision=REV));load_s=time.perf_counter()-t
 audio=load_audio(args.reference,sample_rate=24000);transcript=Path(args.transcript_file).read_text().strip()
 prompts={};prep={}
 for mode,fn in [('icl',lambda:prepare_clone(model,audio,transcript)),('xvector',lambda:prepare_xvector(model,audio))]:
  t=time.perf_counter();prompts[mode]=fn();prep[mode]=time.perf_counter()-t
 reference_vector=vector(model,np.array(audio))
 env={'model':MODEL,'revision':REV,'dtype':'bf16','system':platform.platform(),'machine':platform.machine(),
  'versions':{k:importlib.metadata.version(k) for k in ['mlx','mlx-audio','transformers','soundfile','numpy']},
  'reference_sha256':digest(Path(args.reference).read_bytes()),'reference_samples':int(audio.shape[0]),'reference_s':audio.shape[0]/24000,
  'transcript_sha256':digest(transcript.encode()),'transcript_chars':len(transcript),'load_s':load_s,'prepare_s':prep,
  'required_prefix_tokens':{k:v.required_prefix_tokens for k,v in prompts.items()}}
 (out/'environment.json').write_text(json.dumps(env,indent=2));print(json.dumps(env),flush=True)
 # A complete seed0 full-input warmup per mode: record but exclude from comparisons.
 for mode in prompts:run(model,prompts[mode],reference_vector,TEXTS['short'],mode,'warmup','full',0,args.interval,out)
 rows=[]
 for seed in args.seeds:
  modes=['icl','xvector'] if seed%2==0 else ['xvector','icl']
  for case in args.cases:
   for schedule in args.schedules:
    if schedule=='full' and seed!=args.seeds[0]:continue
    for mode in modes:
     rows.append(run(model,prompts[mode],reference_vector,TEXTS[case],mode,case,schedule,seed,args.interval,out))
     (out/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
