#!/usr/bin/env python3
import json
from pathlib import Path
lab=Path(__file__).resolve().parent.parent
for f in (lab/'work').glob('report-*.json'):
 r=json.loads(f.read_text());text=json.dumps(r,ensure_ascii=False,indent=2)+'\n'
 if '/Users/' in text or ':\\Users\\' in text:raise ValueError('Local path in '+f.name)
 (lab/'results'/f.name).write_text(text)
for f in ['initial-macos-input-limit-only.json','intermediate-macos-output-t-only.json']:
 r=json.loads((lab/'work'/f).read_text())
 reduced={'description':'Pre-fix run; timestamps alone did not enforce a sample-count limit. Not an accepted final result.','cases':[{'case':c['case'],'audio_samples':c['audio']['samples'],'vad_positive':c['audio']['vad_positive']}for c in r['cases']]}
 (lab/'results'/f).write_text(json.dumps(reduced,indent=2)+'\n')
