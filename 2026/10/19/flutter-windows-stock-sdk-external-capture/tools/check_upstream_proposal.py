#!/usr/bin/env python3
"""Check draft applicability against pinned sources; this is not a native test run."""
import argparse,hashlib,json,pathlib,subprocess,tempfile,urllib.request
parser=argparse.ArgumentParser()
group=parser.add_mutually_exclusive_group()
group.add_argument("--wrapper",action="store_true",help="check the external factory candidate")
group.add_argument("--policy",action="store_true",help="check the three-path candidate instead of the first slice")
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];manifest=json.loads((root/('upstream/wrapper-policy-inputs.json' if args.wrapper else 'upstream/core-policy-inputs.json' if args.policy else 'upstream/source-inputs.json')).read_text());pin=manifest['wrapperCommit' if args.wrapper else 'nativeCommit'];patch=root/('upstream/03-external-factory-draft.patch' if args.wrapper else 'upstream/02-recording-policy.patch' if args.policy else 'upstream/01-audio-state-draft.patch')
repo='libwebrtc' if args.wrapper else 'webrtc'
with tempfile.TemporaryDirectory()as directory:
 folder=pathlib.Path(directory)
 for name,sha in manifest['files'].items():
  with urllib.request.urlopen(f'https://raw.githubusercontent.com/webrtc-sdk/{repo}/{pin}/{name}')as response:data=response.read()
  assert hashlib.sha256(data).hexdigest()==sha,name
  target=folder/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
 subprocess.run(['git','apply','--check','--whitespace=error',str(patch)],cwd=folder,check=True)
 subprocess.run(['git','apply',str(patch)],cwd=folder,check=True)
 if args.wrapper:
  assert 'SetAudioRecording(false)' in (folder/'src/rtc_peerconnection_impl.cc').read_text()
  assert 'CreateRTCPeerConnectionFactory();' in (folder/'include/libwebrtc.h').read_text()
 else:
  assert 'if (recording_enabled_ && !adm->Recording())'in(folder/'audio/audio_state.cc').read_text()
  assert 'EXPECT_CALL(*adm, InitRecording()).Times(0);'in(folder/'audio/audio_state_unittest.cc').read_text()
print('Candidate' if args.policy or args.wrapper else 'Draft', 'patch hash/applicability PASS. This check does not compile or run native tests, validate device isolation, or validate the wrapper policy.')
