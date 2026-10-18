#!/usr/bin/env python3
"""Export only the tested protocol surface from version-matched CLI schemas."""
import hashlib,json,subprocess,platform
from pathlib import Path
root=Path(__file__).resolve().parent.parent
selected=['ThreadRealtimeStartParams','ThreadRealtimeAppendAudioParams','ThreadRealtimeAppendTextParams','ThreadRealtimeAppendSpeechParams','ThreadRealtimeStopParams','ThreadRealtimeTranscriptDeltaNotification','ThreadRealtimeTranscriptDoneNotification','ThreadRealtimeOutputAudioDeltaNotification','ThreadRealtimeItemTranscriptDeltaNotification']
for version,source in [('0.159.3','schema'),('0.163.0','schema-latest')]:
 out=root/'schemas'/version;out.mkdir(parents=True,exist_ok=True)
 for name in selected:
  p=root/'work'/source/'v2'/f'{name}.json';(out/p.name).write_text(p.read_text()+'\n')
 schema=json.loads((root/'work'/source/'v2/TurnStartParams.json').read_text())
 user=schema['definitions']['UserInput']
 definitions={}
 def refs(value):
  if isinstance(value,dict):
   if '$ref'in value:yield value['$ref'].split('/')[-1]
   for item in value.values():yield from refs(item)
  elif isinstance(value,list):
   for item in value:yield from refs(item)
 pending=list(refs(user))
 while pending:
  name=pending.pop()
  if name not in definitions:
   definitions[name]=schema['definitions'][name];pending.extend(refs(definitions[name]))
 (out/'UserInput.json').write_text(json.dumps({'$schema':schema['$schema'],'title':'UserInput','definitions':definitions,**user},indent=2)+'\n')
 all_methods=json.loads((root/'work'/source/'ClientRequest.json').read_text())
 methods=[x['properties']['method']['enum'][0]for x in all_methods['oneOf']]
 notifications=json.loads((root/'work'/source/'ServerNotification.json').read_text())
 events=[x['properties']['method']['enum'][0]for x in notifications['oneOf']]
 (out/'methods.json').write_text(json.dumps({'requests':[x for x in methods if '/realtime/'in x],'notifications':[x for x in events if '/realtime/'in x]},indent=2)+'\n')
source=root/'work/codex'
paths=['codex-rs/core/src/realtime_conversation.rs','codex-rs/codex-api/src/endpoint/realtime_websocket/methods_v2.rs','codex-rs/codex-api/src/endpoint/realtime_websocket/methods.rs','codex-rs/core/src/context_manager/normalize.rs']
manifest={'date':'2026-10-19','platform':'macOS 27.0.1 arm64','node':subprocess.check_output(['node','--version'],text=True).strip(),'python':platform.python_version(),'cli_installed':'0.159.3','cli_isolated_stable':'0.163.0','npm_package':'@openai/codex@0.163.0','websockets':'16.0','aiortc':'1.15.0','source_repository':'https://github.com/openai/codex','source_ref':'rust-v0.163.0','source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip(),'source_sha256':{p:hashlib.sha256((source/p).read_bytes()).hexdigest()for p in paths},'fixture_source_sha256':'20e1c86950574d95ad72ed2d324407aa7e48d6013a5d556cdd9517fb71e412ff','fixture_pcm_sha256':hashlib.sha256((root/'work/fixture.pcm').read_bytes()).hexdigest(),'audio_format':{'encoding':'PCM signed16 little-endian','sample_rate':24000,'channels':1}}
(root/'results/manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
