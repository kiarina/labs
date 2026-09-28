"""Fetch the pinned public example motion for local testing only."""
from pathlib import Path
import hashlib,json,urllib.request
root=Path(__file__).resolve().parents[1];report=json.loads((root/'results/body-motion-source.json').read_text());dest=root/'artifacts/body-motion/samba.fbx'
if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest()==report['sha256']:print('Pinned motion already present')
else:
 data=urllib.request.urlopen(report['url'],timeout=60).read();assert hashlib.sha256(data).hexdigest()==report['sha256'],'Source bytes changed';dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data);print('Pinned motion downloaded and verified')
