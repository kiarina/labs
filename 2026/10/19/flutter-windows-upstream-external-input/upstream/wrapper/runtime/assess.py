#!/usr/bin/env python3
"""Assess a fresh submitted-wrapper runtime run without touching earlier results."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('evidence', type=Path, help='private evidence directory with trials/ and abi-summary.json')
parser.add_argument('output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
manifest = args.evidence / 'sdk-manifest.json'
args.output.mkdir(parents=True, exist_ok=True)
summary_path = args.output / 'summary.json'
subprocess.run([sys.executable, str(root / 'tools/assess_trials.py'),
                str(args.evidence / 'trials'), str(summary_path),
                '--sdk-manifest', str(manifest)], check=True)
summary = json.loads(summary_path.read_text())
expected = json.loads((Path(__file__).parent.parent / 'validation.json').read_text())
assert summary['sdk']['dllSha256'] == expected['dllSha256']
summary['upstreamPRCreated'] = True
summary['corePR'] = 'https://github.com/webrtc-sdk/webrtc/pull/314'
summary['wrapperPR'] = 'https://github.com/webrtc-sdk/libwebrtc/pull/158'
summary['stopObservation'] = {'settleMs': 1000, 'observeMs': 1000,
                              'silenceRmsLimit': 1 / 32768,
                              'packetSilenceRequired': False}
for label in ['external-native-playout-off', 'external-track-gates-playout-off',
              'external-replace-gates-playout-off']:
    trial = summary['trials'][label]
    windows = trial['stopWindows']
    idle = [phase for phase in trial['capturePhaseDeltas'] if phase['name'].startswith('idle-after-')]
    trial['offWindowPass'] = bool(
        len(windows) == 2 and len(idle) == 2
        and all(w['rms'] <= 1 / 32768 for w in windows)
        and all(phase['delta']['injectedAudio'] == phase['delta']['injectedVideo'] == 0
                and phase['delta']['rawBytes'] > 0 and phase['delta']['videoFrames'] > 0
                for phase in idle))
    trial['twoResumptionsPass'] = bool(
        trial.get('captureIsolationPass') and trial['offWindowPass']
        and len(trial['receiver']) == 2
        and all(w['pcmSamples'] > 0 and w['rms'] > 0 and w['videoFrames'] > 0
                for w in trial['receiver'])
        and trial['audioRtpAdvancedAcrossGates'])
summary['stopResumeAndPcmPass'] = all(summary['trials'][label]['twoResumptionsPass'] for label in
    ['external-native-playout-off', 'external-track-gates-playout-off', 'external-replace-gates-playout-off'])
abi = json.loads((args.evidence / 'abi-summary.json').read_text(encoding='utf-8-sig'))
summary['oldFlutterBinaryCompatibilityPass'] = bool(
    abi['dllSha256'] == summary['sdk']['dllSha256'] and abi['exitCode'] == 0
    and not abi['errors'] and abi['loadedDllMatches'] and abi['endpointVolumeMuteUnchanged']
    and abi['oldAppSha256'] == 'd9728452c5efab99161276bce356a5ec39830ae4d7e0c1bbfa811cfb1187857f'
    and abi['oldPluginSha256'] == '5e5ee5ac0cc8429ccfd259f2b2d534287ba6d902a2668722584702c0f4023441')
(args.output / 'abi.json').write_text(json.dumps(abi, indent=2) + '\n')
summary_path.write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({key: value for key, value in summary.items() if key not in ['sdk', 'trials']}))
