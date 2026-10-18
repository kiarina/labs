#!/usr/bin/env python3
"""Materialize a lab-local flutter_webrtc; never modify the pub cache."""
import hashlib,json,pathlib,subprocess,tarfile,urllib.request,io
root=pathlib.Path(__file__).resolve().parents[1]
version='1.6.2+hotfix.4'
target=root/'vendor/flutter_webrtc'
if not target.exists():
    with urllib.request.urlopen(f'https://pub.dev/api/packages/flutter_webrtc/versions/{version}') as response:
        metadata=json.load(response)
    with urllib.request.urlopen(metadata['archive_url']) as response:
        archive=response.read()
    if hashlib.sha256(archive).hexdigest()!=metadata['archive_sha256']:
        raise RuntimeError('pub.dev archive checksum mismatch')
    target.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive),mode='r:gz') as tf:
        tf.extractall(target,filter='data')
subprocess.run(['python3',str(root/'patches/android/apply.py'),str(target)],check=True)
print('Prepared vendor/flutter_webrtc (Android patch; other platforms unchanged)')
