#!/usr/bin/env python3
"""Synthesize the fixed Japanese prompts with macOS `say` (no paid generation)."""
import hashlib,json,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[1]
questions={
 'q1':'日本の四季について、それぞれ一文ずつ話してください。',
 'q2':'富士山について、三つの文で説明してください。',
 'q3':'東京のおすすめの観光地を三つ、短く教えてください。',
}
out=root/'app/assets/questions';out.mkdir(parents=True,exist_ok=True);(root/'build').mkdir(exist_ok=True)
report={'voice':'Kyoko','sampleRate':48000,'questions':{}}
for key,text in questions.items():
 aiff=root/'build'/(key+'.aiff');pcm=out/(key+'.pcm')
 subprocess.run(['say','-v','Kyoko','-o',str(aiff),text],check=True)
 subprocess.run(['ffmpeg','-v','error','-y','-i',str(aiff),'-ac','1','-ar','48000','-f','s16le',str(pcm)],check=True)
 data=pcm.read_bytes();report['questions'][key]={'text':text,'seconds':round(len(data)/96000,3),'pcmSha256':hashlib.sha256(data).hexdigest()}
(root/'results/questions.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(json.dumps(report,ensure_ascii=False))
