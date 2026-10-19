#!/usr/bin/env python3
"""Same finalized PCM chunks, native Apple helper versus baseline whisper.cpp."""
import ctypes as c,hashlib,json,platform,subprocess,time,wave
from pathlib import Path
root=Path(__file__).resolve().parents[1]
refs=json.loads((root/'fixtures/segments.json').read_text())
(root/'work/apple-requests.json').write_text(json.dumps([{k:r[k]for k in ['id','speaker_id','start','end','path']}for r in refs]))
subprocess.run(['dart','tools/apple_bridge.dart'],cwd=root,check=True,timeout=180)
lib=c.CDLL(str(root/'work/build/libsegment_whisper.dylib'))
lib.wcpp_init_from_file.argtypes=[c.c_char_p,c.c_int];lib.wcpp_init_from_file.restype=c.c_void_p
lib.wcpp_free.argtypes=[c.c_void_p];lib.wcpp_transcribe.argtypes=[c.c_void_p,c.POINTER(c.c_float),c.c_int,c.c_char_p,c.c_int,c.c_int,c.c_int,c.c_int,c.c_float,c.c_int]
lib.wcpp_n_segments.argtypes=[c.c_void_p];lib.wcpp_segment_text.argtypes=[c.c_void_p,c.c_int];lib.wcpp_segment_text.restype=c.c_char_p
lib.wcpp_system_info.restype=c.c_char_p;lib.wcpp_backend.restype=c.c_char_p
start=time.perf_counter();ctx=lib.wcpp_init_from_file(str(root/'work/ggml-small.bin').encode(),1);load=time.perf_counter()-start
assert ctx
segments=json.loads((root/'fixtures/segments.json').read_text());rows=[]
try:
 for trial in range(3):
  for seg in (list(reversed(segments))if trial==2 else segments):
   t=time.perf_counter()
   with wave.open(str(root/seg['path']))as w:raw=w.readframes(w.getnframes())
   import array
   values=array.array('h');values.frombytes(raw);data=(c.c_float*len(values))(*(v/32768 for v in values));prepared=time.perf_counter()-t
   code=lib.wcpp_transcribe(ctx,data,len(values),b'ja',4,0,1,1,c.c_float(0),0);assert code==0
   text=''.join(lib.wcpp_segment_text(ctx,i).decode()for i in range(lib.wcpp_n_segments(ctx))).strip()
   rows.append({'id':seg['id'],'speaker_id':seg['speaker_id'],'source_start':seg['start'],'source_end':seg['end'],'trial':trial,'text':text,'request_seconds':time.perf_counter()-t,'prepare_seconds':prepared,'binding':'request_id'})
finally:lib.wcpp_free(ctx)
r={'engine':'whisper.cpp','version':'v1.9.5','model':'small multilingual f16','model_sha256':hashlib.sha256((root/'work/ggml-small.bin').read_bytes()).hexdigest(),'gpu':True,'threads':4,'fit_audio_ctx':False,'audio_ctx':0,'no_context':True,'suppress_non_speech':True,'temperature':0,'sampling':'greedy with default fallback','model_load_seconds':load,'backend':lib.wcpp_backend().decode(),'system_info':lib.wcpp_system_info().decode(),'rows':rows}
(root/'results/whisper.json').write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n')
env={'os':subprocess.check_output(['sw_vers'],text=True),'arch':platform.machine(),'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),'memory_bytes':int(subprocess.check_output(['sysctl','-n','hw.memsize'],text=True)),'swift':subprocess.check_output(['swift','--version'],text=True),'dart':subprocess.check_output(['dart','--version'],stderr=subprocess.STDOUT,text=True),'python':platform.python_version(),'fixture_pcm_sha256':'aef288721e2f461c844ef766264cbcf09d997baf34fd72872faaebf0618dd06e','execution_order':'Apple block (18 requests), then Whisper block (18 requests); sequential, not simultaneous','network_audio_upload':False,'physical_microphone_used':False}
(root/'results/environment.json').write_text(json.dumps(env,ensure_ascii=False,indent=2)+'\n');print('Whisper results:',len(rows),flush=True)
