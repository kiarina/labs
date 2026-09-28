"""Build a local macOS test voice with known vowel cues and measured RMS.

No phoneme inference: every cue is known because each vowel is synthesized
separately. Keep generated media local; OS voice updates can change the bytes.
"""
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

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts'/os.environ.get('AUDIO_RUN','vowel-audio')
OUT.mkdir(parents=True,exist_ok=True)
voice=os.environ.get('TEST_VOICE','Kyoko');rate=140;sample_rate=22050
scripts=[('aa','あー。'),('ih','いー。'),('ou','うー。'),('ee','えー。'),('oh','おー。')]
step=round(sample_rate*.01)
def rms(samples):return math.sqrt(sum(x*x for x in samples)/max(1,len(samples)))/32768
def read_pcm(path):
    with wave.open(str(path),'rb') as f:
        assert (f.getnchannels(),f.getsampwidth(),f.getframerate())==(1,2,sample_rate)
        data=array.array('h',f.readframes(f.getnframes()))
    if sys.byteorder!='little':data.byteswap()
    return list(data)
def write_pcm(path,samples):
    data=array.array('h',samples)
    if sys.byteorder!='little':data.byteswap()
    with wave.open(str(path),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(sample_rate);f.writeframes(data.tobytes())

joined=[0]*round(sample_rate*.35);cues=[];sources=[]
for vowel,text in scripts:
    text_file=OUT/f'{vowel}.txt';text_file.write_text(text,encoding='utf-8')
    filename=f'raw-{vowel}.wav'
    command=['say','-v',voice,'-r',str(rate),'-f',text_file.name,'-o',filename,'--file-format=WAVE','--data-format=LEI16@22050']
    subprocess.run(command,cwd=OUT,check=True)
    pcm=read_pcm(OUT/filename)
    energy=[rms(pcm[i:i+step]) for i in range(0,len(pcm),step)]
    threshold=max(.003,max(energy)*.06)
    active=[i for i,value in enumerate(energy) if value>threshold]
    assert active,f'No speech energy for {vowel}'
    start=max(0,active[0]*step-round(sample_rate*.03))
    end=min(len(pcm),(active[-1]+1)*step+round(sample_rate*.03))
    segment=pcm[start:end]
    cue_start=len(joined)/sample_rate;joined.extend(segment);cue_end=len(joined)/sample_rate
    cues.append({'vowel':vowel,'start':cue_start,'end':cue_end,'text':text})
    joined.extend([0]*round(sample_rate*.4))
    sources.append({'vowel':vowel,'text':text,'command':command,'rawSha256':hashlib.sha256((OUT/filename).read_bytes()).hexdigest(),'trimStartFrame':start,'trimEndFrame':end})
joined.extend([0]*round(sample_rate*.2))
wav=OUT/'vowels.wav';write_pcm(wav,joined)
energy=[rms(joined[i:i+step]) for i in range(0,len(joined),step)]
active=sorted(v for v in energy if v>.003);reference=active[int((len(active)-1)*.9)]
threshold=max(.003,reference*.06)
raw=[max(0,min(1,(v-threshold)/(reference-threshold))) for v in energy]
envelope=[]
for i in range(len(raw)):
    envelope.append(round(sum(raw[j]*w for j,w in [(i-2,1),(i-1,2),(i,3),(i+1,2),(i+2,1)] if 0<=j<len(raw))/9,6))
manifest={'version':1,'audio':'vowels.wav','audioSha256':hashlib.sha256(wav.read_bytes()).hexdigest(),
    'duration':len(joined)/sample_rate,'sampleRate':sample_rate,'cues':cues,
    'envelope':{'step':step/sample_rate,'origin':step/(2*sample_rate),'values':envelope},
    'source':{'tool':'macOS say','voice':voice,'rate':rate,'osVersion':platform.mac_ver()[0],
        'method':'individually synthesized known vowels; trimmed with 30 ms margins; 400 ms gaps',
        'rmsWindowFrames':step,'referenceRms':reference,'noiseThreshold':threshold,
        'smoothing':'centered [1,2,3,2,1]/9; not an inferred phoneme alignment','inputs':sources}}
(OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'duration':manifest['duration'],'sha256':manifest['audioSha256'],'cues':cues},ensure_ascii=False))
