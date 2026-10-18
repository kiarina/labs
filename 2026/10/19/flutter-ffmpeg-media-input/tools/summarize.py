#!/usr/bin/env python3
"""Publish metrics only; exclude microphone device names and local paths."""
from pathlib import Path
import json,re
lab=Path(__file__).resolve().parent.parent
for path in (lab/'work').glob('report-*.json'):
 r=json.loads(path.read_text())
 r.pop('devices',None)
 f=r.get('file',{})
 if 'probe' in f and 'format' in f['probe']:
  # The earlier simulator measurement used the initial full probe response.
  f['probe']['format'].pop('filename',None)
 if 'licenses' in f:f['build_date']=f.pop('licenses')
 text=json.dumps(r,ensure_ascii=False,indent=2)+'\n'
 if '/Users/' in text or re.search(r'[A-Z]:\\\\Users',text):raise ValueError('Local path in '+path.name)
 (lab/'results'/path.name).write_text(text)
