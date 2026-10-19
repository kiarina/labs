#!/usr/bin/env python3
"""Normalize the pinned shared speech fixture; no paid generation/API calls."""
import array,hashlib,json,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[1]
(root/'results').mkdir(exist_ok=True)
source=root.parents[3]/'tests/assets/mp3/conversation_2speaker_14s_16k.mp3'
expected='e671750e8c07ae025096e7184740a9351aed85f42625d56310d6e26b6e5d7e3d'
assert hashlib.sha256(source.read_bytes()).hexdigest()==expected,'Unexpected shared speech fixture'
(root/'build').mkdir(exist_ok=True);(root/'app/assets').mkdir(exist_ok=True)
temp=root/'build/speech-decoded.pcm';out=root/'app/assets/far_speech.pcm'
subprocess.run(['ffmpeg','-v','error','-y','-i',str(source),'-ac','1','-ar','48000','-f','s16le',str(temp)],check=True)
data=array.array('h');data.frombytes(temp.read_bytes());peak=max(abs(x)for x in data);scale=9000/peak
normalized=array.array('h',(round(x*scale) for x in data));out.write_bytes(normalized.tobytes())
report={'source':'tests/assets/mp3/conversation_2speaker_14s_16k.mp3','sourceSha256':expected,'sampleRate':48000,'samples':len(data),'peak':max(abs(x)for x in normalized),'pcmSha256':hashlib.sha256(out.read_bytes()).hexdigest(),'normalization':'PCM16 decoded by ffmpeg, mono48k, normalize peak9000'}
(root/'results/speech-fixture.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
