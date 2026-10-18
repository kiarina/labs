#!/usr/bin/env python3
"""Exploratory same-input delay search; requires fresh physical confirmation."""
import argparse,ctypes as C,json,pathlib,shutil
import numpy as np
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--mode',choices=['delay','long','refined'],default='delay');a=p.parse_args();src=root/'build/trial-5';out=root/('build/raw-'+a.mode+'-search');out.mkdir(exist_ok=True)
r=json.loads((src/'report.json').read_text());raw=np.fromfile(src/'mixed.pcm','<i2');ref=np.fromfile(src/'actual_render.pcm','<i2')
lib=C.CDLL(str(root/'build/aec/libaec_engine.dylib'));ptr=C.POINTER(C.c_int16)
lib.aec_create_config.argtypes=[C.c_int,C.c_int];lib.aec_create_config.restype=C.c_void_p;lib.aec_reverse.argtypes=[C.c_void_p,ptr,C.c_int];lib.aec_capture.argtypes=[C.c_void_p,ptr,ptr,C.c_int,C.c_int];lib.aec_destroy.argtypes=[C.c_void_p]
def pt(x):return x.ctypes.data_as(ptr)
n=len(raw)//480*480;names=[]
models={'delay':[(12,d)for d in (20,40,60,80,100,120,160,200)],'long':[(13,d)for d in (80,100,120)]+[(12,80)],'refined':[(p,d)for p in (14,15)for d in (80,100,120)]}
for preset,delay in [(0,80)]+models[a.mode]:
 name='baseline'if preset==0 else ({12:'linear',13:'longLinear',14:'longRefined',15:'longGentle'}[preset])+str(delay);names.append(name);h=lib.aec_create_config(1,preset);assert h;y=np.zeros(n,np.int16);zero=np.zeros(480,np.int16)
 for i in range(0,n,480):
  v=ref[i:i+480];v=v if len(v)==480 else zero
  assert lib.aec_reverse(h,pt(v),480)==0
  assert lib.aec_capture(h,pt(raw[i:i+480]),pt(y[i:i+480]),480,delay)==0
 lib.aec_destroy(h);y.tofile(out/(name+'.pcm'))
for name in ('raw','near','mixed','actual_render'):shutil.copy2(src/(name+'.pcm'),out/(name+'.pcm'))
for phase in r['phases']:phase['endStats']['comparisonNames']=names[1:]
r['comparison']='offline re-clocked delay search; fresh confirmation required'
(out/'report.json').write_text(json.dumps(r))
