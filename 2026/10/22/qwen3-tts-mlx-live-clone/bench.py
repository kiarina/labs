from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
import platform
import threading
import time
from pathlib import Path
import mlx.core as mx
from mlx.utils import tree_map
import numpy as np
import soundfile as sf
from huggingface_hub import snapshot_download
from mlx_audio.tts.utils import load_model
from inputs import MODEL,REV,REF_TEXT,TEXT,LONG,make_reference
from live import TextSource,prepare_clone,generate_live
from tokenizer_check import check


def load(dtype):
    # Prevent compilation only while loading so float32 casting also reaches the
    # decoder; compilation otherwise captures the original bf16 module weights.
    compile_=mx.compile
    if dtype=='float32': mx.compile=lambda fn,*a,**kw:fn
    try: model=load_model(snapshot_download(MODEL,revision=REV))
    finally: mx.compile=compile_
    if dtype=='float32':
        model.update(tree_map(lambda p:p.astype(mx.float32) if mx.issubdtype(p.dtype,mx.floating) else p,model.parameters()))
        mx.eval(model.parameters())
    return model


def run(model,prompt,case,trial,output,temperature,prefix_frames=0):
    text=LONG if 'long' in case else TEXT
    source=TextSource(model.tokenizer); first=threading.Event();events=[]
    start=time.perf_counter();now=lambda:time.perf_counter()-start
    def log(kind,**extra):events.append({'type':kind,'t':now(),**extra})
    def feed():
        try:
            if case=='full' or case=='long_full':
                source.push(text);log('push',text=text)
            elif case=='long_pause':
                # Supply enough text for ICL prefill AND one complete PCM chunk,
                # then hold the remaining text until output is observed.
                initial=None
                for cut in range(1,len(text)):
                    probe=TextSource(model.tokenizer);probe.push(text[:cut])
                    safe,_,_=probe.poll()
                    if len(safe)>=prompt.required_prefix_tokens+8:
                        initial=text[:cut];break
                if initial is None: raise ValueError('Text too short for ICL prefill plus PCM gate')
                source.push(initial);log('push',text=initial)
                reached=first.wait(30);log('audio_gate',reached=reached)
                if not reached: raise TimeoutError('First-PCM producer gate timed out')
                time.sleep(3)
                tail=text[len(initial):];source.push(tail);log('push',text=tail)
            else:
                # Unicode character deltas, no artificial spaces. 25 chars/s.
                for ch in text:
                    time.sleep(.04);source.push(ch);log('push',text=ch)
        except Exception as exc:
            log('producer_error',error=repr(exc));source.cancel();return
        log('close');source.close()
    producer=threading.Thread(target=feed,daemon=True);producer.start()
    mx.random.seed(0);trace={};chunks=[];error=None
    try:
        generator=generate_live(model,prompt,source,temperature=temperature,trace=trace)
        for pcm in generator:
            arr=np.array(pcm,dtype=np.float32);chunks.append(arr)
            log('pcm',samples=len(arr),sr=model.sample_rate)
            first.set()
            if prefix_frames and len(trace['codes'])>=prefix_frames:
                generator.close();trace['stop']='validation_prefix';break
    except Exception as exc:
        error=repr(exc);log('error',error=error);source.cancel()
    elapsed=now();producer.join(5)
    stem=f'{case}-{trial}';metrics={}
    if chunks:
        audio=np.concatenate(chunks);sf.write(output/f'{stem}.wav',audio,model.sample_rate,subtype='FLOAT')
        arrivals=[e for e in events if e['type']=='pcm'];close=next((e['t'] for e in events if e['type']=='close'),None)
        deadline=arrivals[0]['t'];gap=0
        for e in arrivals:
            gap+=max(0,e['t']-deadline);deadline=max(deadline,e['t'])+e['samples']/e['sr']
        metrics={'first_pcm_s':arrivals[0]['t'],'close_s':close,'before_close':close is not None and arrivals[0]['t']<close,
                 'generate_s':elapsed,'audio_s':len(audio)/model.sample_rate,'rtf':elapsed/(len(audio)/model.sample_rate),
                 'gap_s':gap,'finite':bool(np.isfinite(audio).all()),'peak':float(np.abs(audio).max()),'frames':len(trace['codes'])}
    result={'case':case,'trial':trial,'temperature':temperature,'validation_prefix_frames':prefix_frames,'seed':0,'text':text,'metrics':metrics,'error':error,
            'events':events,'trace':trace}
    (output/f'{stem}.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ('events','trace')},ensure_ascii=False),flush=True)
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--dtype',default='bf16',choices=['bf16','float32'])
    p.add_argument('--output',default='output');p.add_argument('--asset',default='../../../../tests/assets/mp3/conversation_2speaker_14s_16k.mp3')
    p.add_argument('--prefix-frames',type=int,default=0);p.add_argument('--reference',choices=['short','full'],default='short');p.add_argument('--temperature',type=float,default=0.9);p.add_argument('--trials',type=int,default=2)
    p.add_argument('--cases',nargs='+',default=['full','chars','long_full','long_chars','long_pause'])
    args=p.parse_args();output=Path(args.output);output.mkdir(exist_ok=True,parents=True)
    mx.set_cache_limit(1<<30)
    audio,reference=make_reference(args.asset,output,short=args.reference=='short')
    start=time.perf_counter();model=load(args.dtype);load_s=time.perf_counter()-start
    checks=check(model.tokenizer);(output/'tokenizer-check.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
    start=time.perf_counter();prompt=prepare_clone(model,mx.array(audio),'もしもし、もう駅に着いた？' if args.reference=='short' else REF_TEXT);prepare_s=time.perf_counter()-start
    env={'model':MODEL,'revision':REV,'platform':platform.platform(),'python':platform.python_version(),
         'dtype':args.dtype,'reference':args.reference,'packages':{x:importlib.metadata.version(x) for x in ['mlx-audio','mlx','numpy','transformers','soundfile','scipy']},
         'load_s':load_s,'reference_prepare_s':prepare_s,'ref_codec_frames':prompt.ref_codes.shape[2],
         'ref_text_tokens':len(prompt.ref_text_ids),'required_target_prefix_tokens':prompt.required_prefix_tokens,
         'emit_frames':4,'temperature':args.temperature,'seed':0}
    (output/'environment.json').write_text(json.dumps(env,indent=2));print(json.dumps(env),flush=True)
    results=[]
    for trial in range(args.trials):
        for case in args.cases:results.append(run(model,prompt,case,trial,output,args.temperature,args.prefix_frames))
    summary=[{k:v for k,v in r.items() if k not in ('trace','events')} for r in results]
    (output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
    parity=[]
    for trial in range(args.trials):
        for a,b in [('full','chars'),('long_full','long_chars'),('long_full','long_pause')]:
            paths=[output/f'{name}-{trial}.json' for name in (a,b)]
            if not all(x.exists() for x in paths):continue
            rs=[json.loads(x.read_text()) for x in paths]
            if any(r['error'] for r in rs):continue
            codes=[r['trace']['codes'] for r in rs]
            wavs=[sf.read(output/f'{name}-{trial}.wav',dtype='float32')[0] for name in (a,b)]
            parity.append({'a':a,'b':b,'trial':trial,'code_equal':codes[0]==codes[1],
                           'pcm_equal':bool(np.array_equal(*wavs)),'samples':[len(w) for w in wavs]})
    (output/'schedule-parity.json').write_text(json.dumps(parity,indent=2));print('schedule parity',parity,flush=True)
    if any(r['error'] for r in results):raise SystemExit(1)
if __name__=='__main__':main()
