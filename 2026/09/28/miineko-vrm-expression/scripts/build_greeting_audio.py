"""One continuous sentence, with explicitly authored timing tied to its bytes."""
import array
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import wave

root=Path(__file__).resolve().parents[1]
out=root/'artifacts'/os.environ.get('SPEECH_RUN','speech-greeting')
out.mkdir(parents=True,exist_ok=True)
profile=json.loads((root/'fixtures/greeting-timing.json').read_text())
(out/'text.txt').write_text(profile['text'],encoding='utf-8')
command=['say','-v',profile['voice'],'-r',str(profile['rate']),'-f','text.txt','-o','raw.wav','--file-format=WAVE','--data-format=LEI16@22050']
subprocess.run(command,cwd=out,check=True)
raw_hash=hashlib.sha256((out/'raw.wav').read_bytes()).hexdigest()
if raw_hash!=profile['rawAudioSha256']:
    raise SystemExit(f'Voice output changed ({raw_hash}); re-evaluate authored timing before building a manifest.')
with wave.open(str(out/'raw.wav')) as f:
    assert (f.getnchannels(),f.getsampwidth(),f.getframerate())==(1,2,22050)
    pcm=array.array('h',f.readframes(f.getnframes()))
if sys.byteorder!='little':pcm.byteswap()
sr=22050;lead=round(.35*sr);tail=round(.5*sr);step=220
samples=[0]*lead+list(pcm)+[0]*tail
energy=[math.sqrt(sum(x*x for x in samples[i:i+step])/len(samples[i:i+step]))/32768 for i in range(0,len(samples),step)]
active=sorted(x for x in energy if x>.003);reference=active[int((len(active)-1)*.9)];noise=max(.003,reference*.06)
raw=[max(0,min(1,(x-noise)/(reference-noise))) for x in energy]
envelope=[round(sum(raw[j]*w for j,w in [(i-2,1),(i-1,2),(i,3),(i+1,2),(i+2,1)] if 0<=j<len(raw))/9,6) for i in range(len(raw))]
encoded=array.array('h',samples)
if sys.byteorder!='little':encoded.byteswap()
with wave.open(str(out/'speech.wav'),'wb') as f:
    f.setnchannels(1);f.setsampwidth(2);f.setframerate(sr);f.writeframes(encoded.tobytes())
manifest={'version':2,'audio':'speech.wav','text':profile['text'],'duration':len(samples)/sr,'sampleRate':sr,
    'audioSha256':hashlib.sha256((out/'speech.wav').read_bytes()).hexdigest(),
    'transitionSeconds':.06,
    'cues':[{**c,'start':c['start']+lead/sr,'end':c['end']+lead/sr} for c in profile['cues']],
    'envelope':{'step':step/sr,'origin':step/(2*sr),'values':envelope},
    'source':{'tool':'macOS say','voice':profile['voice'],'rate':profile['rate'],'osVersion':platform.mac_ver()[0],
        'command':command,'rawSha256':raw_hash,'method':profile['method'],'rmsWindowFrames':step,'referenceRms':reference,'noiseThreshold':noise}}
(out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'duration':manifest['duration'],'audioSha256':manifest['audioSha256'],'rawSha256':raw_hash}))
