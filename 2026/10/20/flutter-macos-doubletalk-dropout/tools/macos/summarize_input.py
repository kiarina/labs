#!/usr/bin/env python3
"""Aggregate observer stacks without publishing addresses, paths or device IDs."""
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('log',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
events=[]
for line in a.log.read_text(errors='replace').splitlines():
 if line.startswith('INPUT_OBSERVER {'):
  events.append({'event':json.loads(line.split('INPUT_OBSERVER ',1)[1]),'stack':[]})
 elif line.startswith('INPUT_OBSERVER_STACK ') and events:events[-1]['stack'].append(line)
def owner(event):
 stack='\n'.join(event['stack'])
 if 'record_macos' in stack:return 'record'
 if 'WebRTC ' in stack:return 'sdk'
 return 'other'
def objects(kind,who,predicate=lambda e:True):return {e['event']['object'] for e in events if e['event']['kind']==kind and owner(e)==who and predicate(e['event'])}
inputs=lambda e:e['value']==1 and e['scope']==1 and e['bus']==1 and e['status']==0
r={'installed':any(e['event']['kind']=='installed' for e in events),'recordInputNodeEngines':len(objects('AVAudioEngine.inputNode','record')),'sdkInputNodeEngines':len(objects('AVAudioEngine.inputNode','sdk')),'unattributedInputNodeEngines':len(objects('AVAudioEngine.inputNode','other')),'sdkInputEnabledAudioUnits':len(objects('enableIO','sdk',inputs)),'recordInputEnabledAudioUnits':len(objects('enableIO','record',inputs)),'sdkStartedAudioUnits':len(objects('audioUnitStart','sdk')),'notes':['InputNode and SDK input EnableIO are independently attributed through runtime call stacks.','Speaker-only device starts are not counted as microphone capture.','Positive negotiated SDK control is required before interpreting zero SDK input.']}
a.output.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))
