#!/usr/bin/env python3
"""Known-offset / clipped-prefix / ambiguous-signal integration checks, offline."""
import json,subprocess,wave
from pathlib import Path
import numpy as np
from audio_clock import AudioClock
root=Path(__file__).resolve().parents[1]
source=root/'asr/app/assets/conversation.wav'
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(source),'-ar','48000','-ac','1','-c:a','libopus','-b:a','48k',str(root/'work/clock-control.opus')],check=True)
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(root/'work/clock-control.opus'),'-ar','24000','-ac','1','-c:a','pcm_s16le',str(root/'work/clock-control.wav')],check=True)
with wave.open(str(source),'rb')as f:pcm=np.frombuffer(f.readframes(f.getnframes()),dtype='<i2')
with wave.open(str(root/'work/clock-control.wav'),'rb')as f:decoded=np.frombuffer(f.readframes(f.getnframes()),dtype='<i2')
references=np.repeat(pcm,3).astype('<i2');reports=[]
for name,clip in [('known_offset',0),('missing_first_1_5_seconds',36000)]:
 c=AudioClock();echo=np.r_[np.zeros(19200,dtype='<i2'),decoded[clip:]].astype('<i2');c.reflected_input(echo.tobytes())
 for _ in range(10):c.reflected_output(c.echo_samples/24+300)
 for i in range(0,len(references)-12000,12000):c.reference(references[i:i+12000].tobytes(),5000+i/48)
 got=c.update();expected=5000-800+clip/24-300;error=None if not got else abs(got['offset_ms']-expected)
 reports.append({'case':name,'valid':bool(got and got['valid']),'expected_offset_ms':expected,'observed_offset_ms':None if not got else got['offset_ms'],'error_ms':error,'pass':bool(got and got['valid']and error<20),'anchors':len(c.anchors)})
 # Same waveform evidence cannot rescue inconsistent server-clock observations.
 c.clock_pairs=[0,800]*20;conflict=c.update();reports.append({'case':name+'_clock_conflict','pass':bool(conflict and not conflict['valid'])})
silence=AudioClock();silence.reflected_input(bytes(24000*2*4));silence.clock_pairs=[0]*20
for i in range(8):silence.reference(bytes(24000),i*250)
reports.append({'case':'silence_is_not_a_clock_anchor','pass':silence.update()is None})
# A repeated speech fragment has multiple equivalent matches; reject it.
piece=pcm[8000:24000];repeat=np.tile(piece,8);a=AudioClock();a.reflected_input(np.repeat(repeat,3)[::2].astype('<i2').tobytes());a.clock_pairs=[0]*20
for i in range(12):a.reference(np.repeat(piece,3).astype('<i2').tobytes(),i*1000)
reports.append({'case':'repeated_waveform_is_ambiguous','pass':a.update()is None})
r={'ok':all(v['pass']for v in reports),'offline':True,'cases':reports};print(json.dumps(r,indent=2));raise SystemExit(0 if r['ok']else 1)
