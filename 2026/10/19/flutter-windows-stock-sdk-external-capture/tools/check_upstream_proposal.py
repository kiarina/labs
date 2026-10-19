#!/usr/bin/env python3
"""Check draft applicability against pinned sources; this is not a native test run."""
import hashlib,json,pathlib,subprocess,tempfile,urllib.request
root=pathlib.Path(__file__).resolve().parents[1];manifest=json.loads((root/'upstream/source-inputs.json').read_text());pin=manifest['nativeCommit'];patch=root/'upstream/01-audio-state-draft.patch'
with tempfile.TemporaryDirectory()as directory:
 folder=pathlib.Path(directory)
 for name,sha in manifest['files'].items():
  with urllib.request.urlopen(f'https://raw.githubusercontent.com/webrtc-sdk/webrtc/{pin}/{name}')as response:data=response.read()
  assert hashlib.sha256(data).hexdigest()==sha,name
  target=folder/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
 subprocess.run(['git','apply','--check',str(patch)],cwd=folder,check=True)
 subprocess.run(['git','apply',str(patch)],cwd=folder,check=True)
 assert 'if (recording_enabled_ && !adm->Recording())'in(folder/'audio/audio_state.cc').read_text()
 assert 'EXPECT_CALL(*adm, InitRecording()).Times(0);'in(folder/'audio/audio_state_unittest.cc').read_text()
print('Draft patch hash/applicability PASS. Native compilation/tests and complete external-only policy are NOT validated.')
