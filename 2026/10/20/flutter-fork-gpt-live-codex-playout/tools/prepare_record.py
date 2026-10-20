#!/usr/bin/env python3
"""Fetch pinned lab-local record_windows; leave shared pub cache unchanged."""
import hashlib,io,json,pathlib,subprocess,tarfile,urllib.request,sys
root=pathlib.Path(__file__).resolve().parents[1];target=root/'vendor/record_windows';version='2.3.0'
if not target.exists():
 with urllib.request.urlopen('https://pub.dev/api/packages/record_windows/versions/'+version) as f:meta=json.load(f)
 with urllib.request.urlopen(meta['archive_url']) as f:data=f.read()
 if hashlib.sha256(data).hexdigest()!='8195489a47b5e8246985d6213ff65aae1b14e32a0ca45dc5f680e8d503296e1b':raise RuntimeError('record_windows archive hash mismatch')
 target.mkdir(parents=True)
 with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as tf:tf.extractall(target,filter='data')
 (target/'LAB_SOURCE.json').write_text(json.dumps({'package':'record_windows','version':version,'archiveSha256':meta['archive_sha256']},indent=2)+'\n')
subprocess.run([sys.executable,str(root/'patches/record_windows/apply.py'),str(target)],check=True)
print('Prepared explicit AEC_RECORD_RAW=1 lab-local record_windows '+version)
