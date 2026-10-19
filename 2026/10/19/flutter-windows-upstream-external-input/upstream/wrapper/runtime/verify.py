#!/usr/bin/env python3
"""Check retained runtime evidence and reject misleading zero-capture results."""
import copy
import json
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent
summary = json.loads((root / 'results/summary.json').read_text())
abi = json.loads((root / 'results/abi.json').read_text())
expected = json.loads((root.parent / 'validation.json').read_text())['dllSha256']


def valid(s, a):
    try:
        trials = s['trials']
        if s['sdk']['dllSha256'] != expected:
            return False
        for t in trials.values():
            if (t['dllSha256'] != expected or not t['traceLossFree']
                    or not t['allCaptureStacksAvailable'] or t['unknownCaptureClients']
                    or not t['endpointVolumeMuteUnchanged'] or t['errors']):
                return False
        record = trials['record-only']
        native = trials['native-mic-default']
        default = trials['external-default']
        if not (record['recordCaptureStarted'] == 1 and record['sdkCaptureAttempts'] == 0
                and native['sdkCaptureStarted'] == 1 and not native['externalOnly']
                and default['sdkCaptureStarted'] == default['recordCaptureStarted'] == 1
                and not default['externalOnly']):
            return False
        endpoints = {c['endpointSha256'] for c in record['captureClients']}
        if not endpoints or endpoints != {c['endpointSha256'] for c in native['captureClients'] if c['kind'] == 'sdk'}:
            return False
        for name in ['external-only', 'external-muted', 'external-native-playout-off',
                     'external-track-gates-playout-off', 'external-replace-gates-playout-off']:
            t = trials[name]
            if not (t['externalOnly'] and t['recordCaptureStarted'] == 1
                    and t['sdkCaptureAttempts'] == 0 and t['singleRecordContinuity']
                    and t['sourceRms'] > 0 and t['audioRtpAdvancedAcrossGates']):
                return False
        for name in ['external-native-playout-off', 'external-track-gates-playout-off',
                     'external-replace-gates-playout-off']:
            t = trials[name]
            if len(t['receiver']) != 2 or len(t['stopWindows']) != 2:
                return False
            if any(w['pcmSamples'] <= 0 or w['rms'] <= 0 or w['videoFrames'] <= 0 for w in t['receiver']):
                return False
            if any(w['rms'] > 1 / 32768 for w in t['stopWindows']):
                return False
            idle = [p for p in t['capturePhaseDeltas'] if p['name'].startswith('idle-after-')]
            if len(idle) != 2 or any(p['delta']['rawBytes'] <= 0 or p['delta']['videoFrames'] <= 0
                    or p['delta']['injectedAudio'] != 0 or p['delta']['injectedVideo'] != 0 for p in idle):
                return False
        for label, prefix in [('external-track-gates-playout-off', 'native-track-'),
                              ('external-replace-gates-playout-off', 'native-replace-')]:
            if trials[label]['nativeTrackTransitions'] != [prefix + action + '-' + str(cycle)
                    for cycle in [1, 2] for action in ['enable', 'disable']]:
                return False
        return bool(a['dllSha256'] == expected and a['exitCode'] == 0 and not a['errors']
                    and a['loadedDllMatches'] and a['endpointVolumeMuteUnchanged']
                    and a['oldAppSha256'] == 'd9728452c5efab99161276bce356a5ec39830ae4d7e0c1bbfa811cfb1187857f'
                    and a['oldPluginSha256'] == '5e5ee5ac0cc8429ccfd259f2b2d534287ba6d902a2668722584702c0f4023441')
    except (KeyError, TypeError):
        return False


assert valid(summary, abi), 'Runtime evidence does not meet the stated criteria'
for mutation in ['lost', 'missing-positive', 'wrong-dll', 'extra-capture', 'no-pcm', 'loud-off', 'injected-off']:
    bad = copy.deepcopy(summary)
    if mutation == 'lost':
        bad['trials']['external-only']['traceLossFree'] = False
    elif mutation == 'missing-positive':
        bad['trials']['native-mic-default']['sdkCaptureStarted'] = 0
    elif mutation == 'wrong-dll':
        bad['trials']['external-only']['dllSha256'] = '0' * 64
    elif mutation == 'extra-capture':
        bad['trials']['external-only']['sdkCaptureAttempts'] = 1
    elif mutation == 'no-pcm':
        bad['trials']['external-native-playout-off']['receiver'][1]['pcmSamples'] = 0
    elif mutation == 'loud-off':
        bad['trials']['external-track-gates-playout-off']['stopWindows'][0]['rms'] = .1
    elif mutation == 'injected-off':
        p = next(p for p in bad['trials']['external-replace-gates-playout-off']['capturePhaseDeltas'] if p['name'].startswith('idle-after-'))
        p['delta']['injectedAudio'] = 1
    assert not valid(bad, abi), mutation
bad_abi = copy.deepcopy(abi)
bad_abi['oldAppSha256'] = '0' * 64
assert not valid(summary, bad_abi)

build = json.loads((root / 'results/build.json').read_text())
cleanup = json.loads((root / 'results/cleanup.json').read_text())
assert build['dllSha256'] == expected and build['builtWrapperSourceHashesMatch']
assert build['mainDartSha256'] == hashlib.sha256((root / 'main.dart').read_bytes()).hexdigest()
assert cleanup['suiteComplete'] and cleanup['wprNotRecording']
assert cleanup['dedicatedTasksRemaining'] == cleanup['appProcessesRemaining'] == 0
assert cleanup['nativeDllSha256'] == cleanup['runtimeDllSha256'] == expected

permission = json.loads((root / 'results/permission-recheck.json').read_text())
assert permission['userReportedBothDialogsApproved'] and permission['dllSha256'] == expected
for t in permission['trials'].values():
    assert t['lostEvents'] == t['lostBuffers'] == 0 and not t['errors']
    assert t['captureStacksAvailable'] and t['captureInitializeEvents'] == 1
    assert t['sdkCaptureAttempts'] == 0 and t['recordMfStarted'] == t['recordStarts'] == 1
    assert t['endpointVolumeMuteUnchanged']
    assert len(t['receiver']) == 2 and t['receiver'][1]['audioPacketsReceived'] > t['receiver'][0]['audioPacketsReceived'] > 0
normal = permission['trials']['normal']
diagnostic = permission['trials']['diagnostic']
assert all(w['pcmSamples'] == 0 for w in normal['receiver'])
assert '0x887c0030' in normal['renderInitializeHResults']
assert all(w['pcmSamples'] > 0 and w['rms'] > 0 for w in diagnostic['receiver'])
assert diagnostic['stopRms'] == [0, 0]
assert permission['cleanup']['wprNotRecording']
assert permission['cleanup']['appProcessesRemaining'] == permission['cleanup']['dedicatedTasksRemaining'] == 0
print('Submitted-wrapper ETW/stop-resume/PCM/old-binary evidence and eight rejection guards PASS')
