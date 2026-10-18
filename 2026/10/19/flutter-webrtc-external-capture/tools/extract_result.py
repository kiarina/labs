#!/usr/bin/env python3
import json,pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
line=next(line.split('EXTERNAL_RESULT ',1)[1] for line in text.splitlines() if 'EXTERNAL_RESULT ' in line)
data=json.loads(line)
pathlib.Path(sys.argv[2]).write_text(json.dumps(data,indent=2)+'\n')
if not data.get('pass'):raise SystemExit('Experiment failed; inspect '+sys.argv[2])
