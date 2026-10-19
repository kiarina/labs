#!/usr/bin/env python3
"""Summarize the two follow-up runs after the user reported approving both dialogs."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('evidence', type=Path, help='private directory containing normal/ and diagnostic/')
parser.add_argument('cleanup', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent
expected = json.loads((root.parent / 'validation.json').read_text())['dllSha256']
result = {'userReportedBothDialogsApproved': True,
          'originalDialogTitlesCaptured': False,
          'firewallRulesObserved': 'Both app executables have enabled Allow rules for Private/Public; no rules were changed by the agent',
          'dllSha256': expected, 'trials': {}}
for label in ['normal', 'diagnostic']:
    folder = args.evidence / label
    app = json.loads((folder / 'upstream_input_result.json').read_text(encoding='utf-8-sig'))
    etw = json.loads((folder / 'normalized.json').read_text(encoding='utf-8-sig'))
    assert app['sdkIdentity']['sha256'] == expected
    capture = [e for e in etw['events'] if e['event'] == 'AudioClientInitialize' and e['data'].get('StreamType') == '1']
    modules = lambda e: {f.get('module', '').lower() for f in e.get('stack', [])}
    packets = lambda phase: sum(int(float(s.get('packetsReceived', 0))) for s in phase['inbound'] if s.get('kind') == 'audio')
    result['trials'][label] = {
        'errors': app['errors'], 'lostEvents': etw['lostEvents'], 'lostBuffers': etw['lostBuffers'],
        'captureInitializeEvents': len(capture),
        'captureStacksAvailable': all(e.get('stack') for e in capture),
        'sdkCaptureAttempts': sum('libwebrtc.dll' in modules(e) for e in capture),
        'recordMfStarted': sum('mfcore.dll' in modules(c['initialize']) and 'libwebrtc.dll' not in modules(c['initialize']) for c in etw['captureStartedClients']),
        'recordStarts': app['captureStarts']['record'],
        'receiver': [{'pcmSamples': p['pcmSamples'], 'rms': p['rms'], 'videoFrames': p['videoFrames'], 'audioPacketsReceived': packets(p)} for p in app['receiver']],
        'stopRms': [w['rms'] for w in app['stopWindows']],
        'renderInitializeHResults': [e['data'].get('HResult') for e in etw['renderInitializeEvents']],
        'endpointVolumeMuteUnchanged': (folder / 'volume-before.txt').read_bytes() == (folder / 'volume-after.txt').read_bytes(),
        'traceInputSha256': etw['inputSha256'],
    }
result['cleanup'] = json.loads(args.cleanup.read_text(encoding='utf-8-sig'))
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
