#!/usr/bin/env python3
"""Check the proposal and retained evidence; no native build or device access."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, help='pristine checkout at the pinned main')
args = parser.parse_args()
root = Path(__file__).resolve().parent
inputs = json.loads((root / 'inputs.json').read_text())
validation = json.loads((root / 'validation.json').read_text())
sha = lambda content: hashlib.sha256(content).hexdigest()
patch = root / 'factory-policy.patch'
assert sha(patch.read_bytes()) == inputs['patchSha256'] == validation['patchSha256']
assert validation['wrapperCommit'] == inputs['wrapperCommit']
assert validation['coreCommit'] == inputs['coreCommit']
assert validation['builtSourceHashesMatch'] and validation['buildPassed']
for name, count in [('audio-device-tests.json', 4), ('all-tests.json', 25)]:
    result = json.loads((root / name).read_text())
    assert result['tests'] == count and result['failures'] == 0
    assert result['errors'] == result['disabled'] == 0
    cases = [case for suite in result['testsuites'] for case in suite['testsuite']]
    assert len(cases) == count
    assert all(case['status'] == 'RUN' and case['result'] == 'COMPLETED' for case in cases)
with tempfile.TemporaryDirectory() as directory:
    folder = Path(directory)
    for name, expected in inputs['files'].items():
        if args.source:
            content = (args.source / name).read_bytes()
        else:
            url = f'https://raw.githubusercontent.com/webrtc-sdk/libwebrtc/{inputs["wrapperCommit"]}/{name}'
            with urllib.request.urlopen(url) as response:
                content = response.read()
        assert sha(content) == expected, name
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    subprocess.run(['git', 'apply', '--check', '--whitespace=error', str(patch)], cwd=folder, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=folder, check=True)
    for name, expected in inputs['patchedFiles'].items():
        assert sha((folder / name).read_bytes()) == expected, name
print('Proposal source/patch hashes, strict application and retained 4/25 tests PASS')
print('This does not rerun native tests, ETW, ABI runtime or other OS builds')
