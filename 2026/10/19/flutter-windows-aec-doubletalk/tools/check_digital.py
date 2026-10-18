#!/usr/bin/env python3
"""Run the two device-free profiles and require their explicit PASS result."""
import json,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[1]
probe=root/'build/aec/aec_digital_probe'
if sys.platform=='win32':probe=root/'build/aec/Release/aec_digital_probe.exe'
for preset in (0,12,14):
 result=json.loads(subprocess.check_output([str(probe),str(preset)],text=True))
 assert result['pass'],result
 print(json.dumps({'preset':preset,'pass':result['pass'],'doubleTalk':result['doubleTalk']}))
