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
from live import TextSource, prepare_clone
from boundary import prepare_boundary_session
from decouple import generate
from segments import generate_segments

MODEL='mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16'
REV='a6eb4f68e4b056f1215157bb696209bc82a6db48'
TEXTS={
 'ja':'うん、今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？',
 'en':'Tokyo is a busy city with quiet gardens and many small cafes. We can take a short walk and have some tea later.',
}
LANG={'ja':'japanese','en':'english'}
def digest(b):return hashlib.sha256(b).hexdigest()

def run(model,prompt,case,mode,seed,schedule,out):
    prepared=prepare_boundary_session(model,prompt,'fresh_prefix')
    source=TextSource(model.tokenizer);text=TEXTS[case];events=[];trace={};chunks=[];error=None
    interval=.13 if case=='ja' else .06
    start=time.perf_counter();now=lambda:time.perf_counter()-start
    def feed():
        try:
            if schedule=='full':source.push(text);events.append({'type':'append','t':now(),'chars':len(text)})
            elif schedule=='recorded':
                import math
                cadence=json.loads(Path('schedules.json').read_text())[case];cursor=0
                for item in cadence['arrivals']:
                    time.sleep(max(0,start+item['t']-time.perf_counter()))
                    through=min(len(text),math.ceil(len(text)*item['fraction']))
                    if through>cursor:
                        source.push(text[cursor:through]);cursor=through
                        events.append({'type':'append','t':now(),'chars':len(source.text)})
                time.sleep(max(0,start+cadence['done_s']-time.perf_counter()))
            else:
                for i,ch in enumerate(text):
                    if source.cancelled:return
                    if schedule=='pause' and i==len(text)*2//3:
                        events.append({'type':'pause','t':now(),'duration_s':2.});time.sleep(2.)
                    source.push(ch);events.append({'type':'append','t':now(),'chars':len(source.text)});time.sleep(interval)
            events.append({'type':'text.done','t':now()});source.close()
        except Exception as exc:
            events.append({'type':'producer_error','t':now(),'error':repr(exc)});source.cancel()
    producer=threading.Thread(target=feed,daemon=True);producer.start();mx.random.seed(seed)
    try:
        generator=generate_segments(model,prompt,source,prepared,case,trace,cached=mode=='segments_cached') if mode in ['segments','segments_cached'] else generate(model,prompt,source,prepared,mode,trace)
        for pcm in generator:
            a=np.array(pcm,dtype=np.float32);chunks.append(a)
            events.append({'type':'pcm','t':now(),'samples':len(a),'chars':len(source.text)})
    except Exception as exc:error=repr(exc);source.cancel()
    producer.join(5)
    stem=f'{mode}-{case}-{schedule}-{seed}'
    row={'mode':mode,'case':case,'schedule':schedule,'seed':seed,'text':text,'language':case,
         'interval_s':interval,'error':error,'stop':trace.get('stop'),'prep_s':prepared.prep_s,
         'pads':len(trace['pads']),'frames':len(trace['codes']),'wait_s':sum(e['end']-e['start'] for e in trace['waits']),
         'tokens_consumed':trace.get('consumed_target_tokens'),'tokens_total':trace.get('target_tokens'),
         'total_s':now()}
    arrivals=[e for e in events if e['type']=='pcm'];done=next((e['t'] for e in events if e['type']=='text.done'),None)
    if chunks:
        a=np.concatenate(chunks);sf.write(out/f'{stem}.wav',a,24000,subtype='FLOAT')
        deadline=arrivals[0]['t'];gaps=[]
        for e in arrivals:
            if e['t']>deadline+.02:gaps.append({'start':deadline,'duration':e['t']-deadline})
            deadline=max(deadline,e['t'])+e['samples']/24000
        row.update(first_pcm_s=arrivals[0]['t'],text_done_s=done,before_done=done is not None and arrivals[0]['t']<done,
            gap_s=sum(g['duration'] for g in gaps),gap_count=len(gaps),audio_s=len(a)/24000,
            pcm_sha256=digest(a.tobytes()),finite=bool(np.isfinite(a).all()),peak=float(np.max(np.abs(a))))
        row['gap_intervals']=gaps
    (out/f'{stem}.json').write_text(json.dumps({'result':row,'events':events,'trace':trace},ensure_ascii=False,indent=2))
    print(json.dumps(row,ensure_ascii=False),flush=True)
    return row

def main():
    p=argparse.ArgumentParser();p.add_argument('--reference',required=True);p.add_argument('--transcript-file',required=True)
    p.add_argument('--output',default='output');p.add_argument('--modes',nargs='+',default=['strict','pad4','pad12','pad_free'])
    p.add_argument('--seeds',nargs='+',type=int,default=[42]);p.add_argument('--cases',nargs='+',default=['ja','en'])
    p.add_argument('--schedules',nargs='+',default=['chars']);p.add_argument('--controls',action='store_true')
    a=p.parse_args();out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
    model=load_model(snapshot_download(MODEL,revision=REV));audio=load_audio(a.reference,sample_rate=24000)
    transcript=Path(a.transcript_file).read_text().strip();prompts={c:prepare_clone(model,audio,transcript,LANG[c]) for c in a.cases}
    env={'model':MODEL,'revision':REV,'hardware':platform.machine(),'python':platform.python_version(),
         'versions':{x:importlib.metadata.version(x) for x in ['mlx','mlx-audio','numpy','transformers']},
         'reference_sha256':digest(Path(a.reference).read_bytes()),'reference_samples':int(audio.shape[0]),
         'transcript_sha256':digest(transcript.encode()),'max_frames':500,'emit_frames':4,'temperature':.9,'top_k':50,'top_p':1.,'repetition_penalty':1.05}
    (out/'environment.json').write_text(json.dumps(env,indent=2))
    # One warmup through the same model kernels; excluded, but retained.
    run(model,prompts[a.cases[0]],a.cases[0],'strict',0,'full',out)
    rows=[]
    for seed in a.seeds:
        for case in a.cases:
            schedules=(['full'] if a.controls and seed==a.seeds[0] else [])+a.schedules
            for schedule in schedules:
                modes=(['strict','pad_free'] if schedule=='full' and a.controls else a.modes)
                if seed%2:modes=list(reversed(modes))
                for mode in modes:
                    rows.append(run(model,prompts[case],case,mode,seed,schedule,out))
                    (out/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
