import json,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1];mode=sys.argv[1]
rows=[json.loads(line)for line in(root/f'work/online-{mode}.log').read_text().splitlines()if line.startswith('{')]
assert len(rows)==1 and rows[0]['mode']==('streaming'if mode=='one-speaker'else mode)
(root/f'results/online-{mode}.json').write_text(json.dumps(rows[0],ensure_ascii=False,indent=2)+'\n')
