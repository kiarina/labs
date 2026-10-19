#!/usr/bin/env python3
"""Verify source hashes and patch application only; no compilation/device test."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('kind', choices=['core', 'factory'])
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
core = args.kind == 'core'
manifest = json.loads((root / 'sdk' / ('core-inputs.json' if core else 'wrapper-inputs.json')).read_text())
repo = 'webrtc' if core else 'libwebrtc'
pin = manifest['nativeCommit' if core else 'wrapperCommit']
with tempfile.TemporaryDirectory() as directory:
    folder = Path(directory)
    for name, sha in manifest['files'].items():
        with urllib.request.urlopen(f'https://raw.githubusercontent.com/webrtc-sdk/{repo}/{pin}/{name}') as response:
            content = response.read()
        assert hashlib.sha256(content).hexdigest() == sha, name
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    patch = root / 'sdk' / (args.kind + '-policy.patch')
    subprocess.run(['git', 'apply', '--check', '--whitespace=error', str(patch)], cwd=folder, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=folder, check=True)
print('Pinned input hashes and patch application PASS; this is not a native build/test')
