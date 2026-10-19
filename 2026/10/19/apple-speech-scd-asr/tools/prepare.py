import hashlib,json,subprocess,tarfile,urllib.request,wave
from pathlib import Path
root=Path(__file__).resolve().parents[1];work=root/'work';work.mkdir(exist_ok=True)
source=root.parents[3]/'tests/assets/mp3/conversation_2speaker_14s_16k.mp3'
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(source),'-ar','16000','-ac','1','-c:a','pcm_s16le',str(work/'source.wav')],check=True)
with wave.open(str(work/'source.wav'))as w:pcm=w.readframes(w.getnframes())
assert hashlib.sha256(pcm).hexdigest()=='aef288721e2f461c844ef766264cbcf09d997baf34fd72872faaebf0618dd06e'
refs=json.loads((root/'fixtures/scd.json').read_text());texts=(root/'fixtures/reference.txt').read_text().splitlines();rows=[]
for i,(r,text)in enumerate(zip(refs,texts)):
 a=round(r['start']*16000);b=round(r['end']*16000);raw=pcm[a*2:b*2];name=f'work/segment-{i+1}.wav'
 with wave.open(str(root/name),'wb')as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(raw)
 rows.append({'id':f'segment-{i+1}','speaker_id':f'speaker-{r["speaker"]+1}','start':a/16000,'end':b/16000,'path':name,'reference':text,'samples':b-a,'pcm_sha256':hashlib.sha256(raw).hexdigest()})
(root/'fixtures/segments.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
(work/'apple-requests.json').write_text(json.dumps([{k:r[k]for k in ['id','speaker_id','start','end','path']}for r in rows]))
archive=work/'whisper-v1.9.5.tar.gz'
if not archive.exists():urllib.request.urlretrieve('https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz',archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720'
if not(work/'whisper.cpp').exists():
 with tarfile.open(archive)as t:t.extractall(work,filter='data')
 (work/'whisper.cpp-1.9.5').rename(work/'whisper.cpp')
model=work/'ggml-small.bin'
if not model.exists():urllib.request.urlretrieve('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',model)
assert hashlib.sha256(model.read_bytes()).hexdigest()=='1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b'
subprocess.run(['cmake','-S','native','-B','work/build','-DCMAKE_BUILD_TYPE=Release'],cwd=root,check=True)
subprocess.run(['cmake','--build','work/build','-j','6'],cwd=root,check=True)
