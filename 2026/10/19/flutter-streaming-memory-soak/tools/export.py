#!/usr/bin/env python3
import json,shutil
from pathlib import Path
root=Path(__file__).resolve().parent.parent
base=Path.home()/'Library/Containers/dev.lab.memorySoakLab/Data/Library/Application Support/dev.lab.memorySoakLab'
labels=['callback-unfixed','callback-fixed','profile-unfixed','profile-fixed','control-idle','control-decode','control-infer','thread-one','thread-two','soak-fixed']
for label in labels:
 source=base/f'{label}.jsonl';text=source.read_text()
 rows=[json.loads(x)for x in text.splitlines()]
 if rows[-1].get('ok')is not True:raise ValueError('Incomplete or failed '+label)
 if '/Users/'in text or ':\\Users\\'in text:raise ValueError('Local path '+label)
 (root/f'results/{label}.jsonl').write_text(text)
for label in ['profile-unfixed-heap-final','profile-fixed-heap-final','profile-idle-heap']:
 # VM auth URI is never part of this metrics-only result.
 r=json.loads((root/f'work/{label}.json').read_text());r.pop('instances_error',None)
 (root/f'results/{label}.json').write_text(json.dumps(r,indent=2)+'\n')
for stem,reason in [
 ('overlap','Concurrent profiling; deliberately stopped'),
 ('two-thread','Unmarked two-thread exploratory timing; deliberately stopped'),
 ('no-activity','Unmarked one-thread exploratory timing; deliberately stopped')]:
 source={'overlap':'soak-overlap-exploratory','two-thread':'soak-two-thread-exploratory','no-activity':'soak-no-activity-exploratory'}[stem]
 rows=[json.loads(x)for x in (root/f'work/{source}.jsonl').read_text().splitlines()]
 result={'accepted':False,'reason':reason+'; not used for final bounds.','passes':[x for x in rows if x['type']=='pass']}
 text=json.dumps(result,indent=2)+'\n'
 if '/Users/' in text:raise ValueError('Local path in exploratory data')
 (root/f'results/exploratory-{stem}.json').write_text(text)
