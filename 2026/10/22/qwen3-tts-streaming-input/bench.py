"""Measure stock live-text TTS; no model or upstream code modifications."""
import argparse
import importlib.metadata
import json
import platform
import threading
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from huggingface_hub import snapshot_download
from qwen_tts import Qwen3TTSModel
from qwen_tts.inference.live_text_source import LiveTextSource

MODEL = 'Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice'
EN = 'Hello there, this is a test of streaming text input while the audio keeps playing.'
JA = 'こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？'
JA_PHRASES = ['こんにちは。', '今日はいい天気ですね。', '少し散歩してから、', '駅前のカフェで', 'コーヒーを飲みませんか？']


def buffer_probe():
    result = []
    for label, fragments in [('ja_chars', list(JA)), ('ja_phrases_space', [p+' ' for p in JA_PHRASES])]:
        source = LiveTextSource()
        polls = []
        for fragment in fragments:
            source.push(fragment)
            polls.append({'fragment': fragment, 'poll': source.poll()})
        source.close()
        result.append({'case': label, 'polls': polls, 'after_close': source.poll()})
    return result


def measure(tts, case, trial, output, speaker):
    torch.manual_seed(0)
    source = LiveTextSource(idle_timeout_s=10)
    first_pcm = threading.Event()
    events, chunks, frames = [], [], []
    start = time.perf_counter()
    now = lambda: time.perf_counter()-start
    def emit(kind, **fields):
        events.append({'type': kind, 't': now(), **fields})
    def feed():
        try:
            if case in ('en_starvation', 'ja_starvation'):
                initial = ' '.join(JA_PHRASES[:2])+' ' if case.startswith('ja') else 'Hello there, this is a test of streaming text input while '
                source.push(initial)
                emit('push', text=initial)
                signaled = first_pcm.wait(30)
                emit('first_pcm_gate', signaled=signaled)
                time.sleep(3)
                tail = ' '.join(JA_PHRASES[2:])+' ' if case.startswith('ja') else 'the audio keeps playing. '
                source.push(tail)
                emit('push', text=tail)
            else:
                if case == 'en_all': fragments, delay = [EN], 0
                elif case == 'en_words': fragments, delay = [w+' ' for w in EN.split()], .05
                elif case == 'ja_all': fragments, delay = [JA], 0
                elif case == 'ja_chars': fragments, delay = list(JA), .08
                elif case == 'ja_phrases_space': fragments, delay = [p+' ' for p in JA_PHRASES], .6
                for fragment in fragments:
                    time.sleep(delay)
                    source.push(fragment)
                    emit('push', text=fragment)
        finally:
            # time of close is logged before calling, conservative for before-close checks.
            emit('close')
            source.close()
    producer = threading.Thread(target=feed, daemon=True)
    producer.start()
    error = None
    try:
        for pcm, sr in tts.stream_generate_custom_voice_live_text(
            text_source=source, speaker=speaker,
            language='Japanese' if case.startswith('ja') else 'English',
            on_frame=lambda step, pad: frames.append({'t':now(),'step':step,'pad':pad}),
            max_frames=1000,
        ):
            received = now()
            pcm = np.asarray(pcm).reshape(-1).copy()
            chunks.append(pcm)
            emit('pcm', received=received, samples=len(pcm), sr=sr)
            first_pcm.set()
            print(f'{case}-{trial}: chunk {len(chunks)} at {received:.3f}s, {len(pcm)/sr:.3f}s PCM',flush=True)
    except Exception as exc:
        error = repr(exc)
        emit('error', error=error)
    elapsed = now()
    producer.join(35)
    pcm_events = [e for e in events if e['type']=='pcm']
    close_time = next((e['t'] for e in events if e['type']=='close'), None)
    metrics = {}
    if chunks:
        audio = np.concatenate(chunks)
        sf.write(output/f'{case}-{trial}.wav', audio, sr, subtype='FLOAT')
        duration = len(audio)/sr
        def gaps(prebuffer):
            accumulated = 0.
            playback_end = None
            total_gap = 0.
            largest = 0.
            pending = []
            for event in pcm_events:
                pending.append(event)
                accumulated += event['samples']/event['sr']
                if playback_end is None and accumulated < prebuffer:
                    continue
                arrival = event['received']
                if playback_end is None:
                    playback_end = arrival
                gap = max(0., arrival-playback_end)
                total_gap += gap
                largest = max(largest, gap)
                playback_end = max(playback_end,arrival)+sum(e['samples']/e['sr'] for e in pending)
                pending=[]
            return {'total_gap_s':total_gap, 'max_gap_s':largest}
        metrics = {'ttfp_s':pcm_events[0]['received'], 'elapsed_s':elapsed,
                   'audio_s':duration, 'rtf':elapsed/duration,
                   'audio_before_close':pcm_events[0]['received'] < close_time if close_time else False,
                   'chunks':len(chunks), 'peak':float(np.max(np.abs(audio))),
                   'finite':bool(np.isfinite(audio).all()),
                   'zero_prebuffer':gaps(0), 'half_second_prebuffer':gaps(.5)}
    result = {'case':case, 'trial':trial,'seed':0,'close_s':close_time,'metrics':metrics,
              'error':error,'events':sorted(events,key=lambda x:x['t']),'frames':frames}
    (output/f'{case}-{trial}.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ('events','frames')},ensure_ascii=False),flush=True)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cases',nargs='+',default=['en_all','en_words','ja_all','ja_chars','ja_phrases_space','en_starvation','ja_starvation'])
    parser.add_argument('--trials',type=int,default=2)
    parser.add_argument('--speaker',default='Vivian')
    parser.add_argument('--revision',default='0c0e3051f131929182e2c023b9537f8b1c68adfe')
    parser.add_argument('--output',default='output')
    args=parser.parse_args()
    output=Path(args.output); output.mkdir(parents=True,exist_ok=True)
    (output/'buffer-probe.json').write_text(json.dumps(buffer_probe(),ensure_ascii=False,indent=2))
    revision=args.revision
    snapshot=snapshot_download(MODEL,revision=revision)
    info={'model':MODEL,'revision':revision,'platform':platform.platform(),
          'processor':platform.processor(),'python':platform.python_version(),
          'packages':{p:importlib.metadata.version(p) for p in ['qwen-tts','torch','torchaudio','transformers','accelerate','numpy','soundfile']},
          'speaker':args.speaker,'device':'mps','dtype':'float32','two_phase':False,'attention':'eager','fast_codebook':True,
          'text':{'en':EN,'ja':JA,'ja_phrases':JA_PHRASES},
          'upstream':'6700c71755dd8cc4b100841c146062542fda484b',
          'settings':'Stock live API defaults except max_frames=1000 safety cap. Seed 0 each run; speaker recorded separately.'}
    start=time.perf_counter()
    tts=Qwen3TTSModel.from_pretrained(snapshot,device_map='mps',dtype=torch.float32,attn_implementation='eager')
    tts.model.talker.enable_fast_codebook_gen(True)
    torch.mps.synchronize()
    info['load_s']=time.perf_counter()-start
    (output/'environment.json').write_text(json.dumps(info,indent=2,ensure_ascii=False))
    print(json.dumps(info,ensure_ascii=False),flush=True)
    results=[]
    for trial in range(args.trials):
        for case in args.cases:
            results.append(measure(tts,case,trial,output,args.speaker))
    (output/'summary.json').write_text(json.dumps([{k:v for k,v in r.items() if k not in ('events','frames')} for r in results],ensure_ascii=False,indent=2))

if __name__=='__main__': main()
