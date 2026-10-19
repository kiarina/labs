#!/usr/bin/env python3
"""Exploratory replay; missing original event order is explicitly approximated."""
import argparse,ctypes as C,json,hashlib
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('artifacts',type=Path);p.add_argument('library',type=Path);p.add_argument('output',type=Path);p.add_argument('--lead-blocks',type=int,default=86);a=p.parse_args()
r=json.loads((a.artifacts/'report.json').read_text());raw=np.fromfile(a.artifacts/'raw.pcm','<i2');ref=np.fromfile(a.artifacts/'actual_render.pcm','<i2');lib=C.CDLL(str(a.library.resolve()));ptr=C.POINTER(C.c_int16)
lib.aec_create_config.argtypes=[C.c_int,C.c_int];lib.aec_create_config.restype=C.c_void_p
lib.aec_reverse.argtypes=[C.c_void_p,ptr,C.c_int];lib.aec_capture.argtypes=[C.c_void_p,ptr,ptr,C.c_int,C.c_int];lib.aec_destroy.argtypes=[C.c_void_p]
def pt(v):return v.ctypes.data_as(ptr)
def db(v):return float(20*np.log10(max(float(v),1e-12)))
def rms(v):return np.sqrt(np.mean(v.astype(float)**2))
a.output.mkdir(parents=True,exist_ok=True);rows=[]
for preset in [0,14,16,17,18]:
 h=lib.aec_create_config(1,preset);assert h;out=np.zeros(len(raw)//480*480,np.int16);ri=0
 for i in range(0,len(out),480):
  upto=min(len(ref)//480*480,i+(a.lead_blocks+1)*480)
  while ri<upto:
   assert lib.aec_reverse(h,pt(ref[ri:ri+480]),480)==0;ri+=480
  assert lib.aec_capture(h,pt(raw[i:i+480]),pt(out[i:i+480]),480,120 if preset==14 else 20)==0
 lib.aec_destroy(h);out.tofile(a.output/f'preset-{preset}.pcm');phases=[]
 for q in r['phases']:
  s=q['start']['rawBytes']//2+48000;e=min(q['end']['rawBytes']//2-24000,len(out)-432)
  if e<=s:continue
  gains=[]
  for t in range(s,e-4800+1,4800):
   x=raw[t:t+4800];y=out[t+432:t+432+4800]
   if db(rms(x)/32768)>-65:gains.append(db(rms(y)/max(rms(x),1e-12)))
  phases.append({'phase':q['name'],'rawRmsDbfs':db(rms(raw[s:e])/32768),'outputRmsDbfs':db(rms(out[s+432:e+432])/32768),'activeWindows':len(gains),'windowsBelowMinus6Db':sum(g<-6 for g in gains),'worstRawRatioDb':min(gains) if gains else None})
 rows.append({'preset':preset,'phases':phases});print(preset,[(q['phase'],q['windowsBelowMinus6Db'],round(q['worstRawRatioDb'] or 0,1))for q in phases if 'doubletalk' in q['phase']],flush=True)
result={'kind':'exploratory-approximate-replay','leadReverseBlocks':a.lead_blocks,'originalEventOrderAvailable':False,'librarySha256':hashlib.sha256(a.library.read_bytes()).hexdigest(),'rawSha256':hashlib.sha256(raw.tobytes()).hexdigest(),'presets':rows,'caveat':'Cadence is approximated; cannot claim byte-identical replay or isolated near gain.'}
(a.output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
