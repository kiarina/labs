#!/usr/bin/env python3
"""Check retained evidence and negative controls without opening any devices."""
import copy
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sdk = json.loads((root / 'results/candidate-sdk.json').read_text())
result = json.loads((root / 'results/summary.json').read_text())


def capture_pass(data, label):
    try:
        trials = data['trials']
        if data['sdk']['dllSha256'] != sdk['dllSha256']:
            return False
        for name in ['record-only', 'native-mic-default', 'external-default', label]:
            trial = trials[name]
            if (trial['dllSha256'] != sdk['dllSha256'] or not trial['traceLossFree']
                    or not trial['allCaptureStacksAvailable'] or not trial['endpointVolumeMuteUnchanged']
                    or trial['unknownCaptureClients'] or not trial['captureClients']):
                return False
        if trials['native-mic-default']['externalOnly'] or trials['native-mic-default']['sdkCaptureStarted'] != 1:
            return False
        if trials['external-default']['externalOnly'] or trials['external-default']['sdkCaptureStarted'] != 1:
            return False
        if trials['record-only']['sdkCaptureAttempts'] or trials['record-only']['recordCaptureStarted'] != 1:
            return False
        endpoints = {c['endpointSha256'] for c in trials['record-only']['captureClients']}
        positive = {c['endpointSha256'] for c in trials['native-mic-default']['captureClients'] if c['kind'] == 'sdk'}
        target = trials[label]
        return bool(endpoints and endpoints == positive and target['externalOnly']
                    and target['recordCaptureStarted'] == 1 and not target['sdkCaptureAttempts']
                    and target['singleRecordContinuity'] and not target['errors']
                    and target['audioRtpAdvancedAcrossGates'] and target['videoDecoded']
                    and target['sourceRms'] > 1e-6)
    except (KeyError, TypeError):
        return False


for name in ['external-only', 'external-muted', 'external-native-playout-off', 'external-track-gates-playout-off', 'external-replace-gates-playout-off']:
    assert capture_pass(result, name), name
assert result['captureIsolationPass'] is True
assert result['mediaFlowPass'] is False  # native render format failure remains
assert result['diagnosticDecodedMediaPass'] is True
assert result['nativeTrackGateDiagnosticPass'] is True
assert result['nativeReplaceGateDiagnosticPass'] is True
assert result['officialSdkValidated'] is False and result['aecValidated'] is False
assert result['physicalWindowsCameraValidated'] is False
assert result['publicWrapperPlayoutApiValidated'] is False
for name in ['external-native-playout-off', 'external-track-gates-playout-off', 'external-replace-gates-playout-off']:
    trial = result['trials'][name]
    assert len(trial['receiver']) == 2 and all(p['pcmSamples'] > 0 and p['rms'] > 1e-6 and p['videoFrames'] > 0 for p in trial['receiver'])
assert len(result['trials']['external-track-gates-playout-off']['nativeTrackTransitions']) == 4
assert len(result['trials']['external-replace-gates-playout-off']['nativeTrackTransitions']) == 4
for field, value in [('traceLossFree', False), ('sdkCaptureAttempts', 1), ('captureClients', []), ('dllSha256', '0' * 64), ('audioRtpAdvancedAcrossGates', False)]:
    altered = copy.deepcopy(result)
    altered['trials']['external-only'][field] = value
    assert not capture_pass(altered, 'external-only'), field
altered = copy.deepcopy(result)
altered['trials']['native-mic-default']['sdkCaptureStarted'] = 0
assert not capture_pass(altered, 'external-only')
abi = json.loads((root / 'results/abi.json').read_text(encoding='utf-8-sig'))
assert abi['dllSha256'] == sdk['dllSha256'] and abi['loadedDllMatches']
assert abi['exitCode'] == 0 and not abi['errors'] and abi['endpointVolumeMuteUnchanged']
wrapper = json.loads((root / 'results/wrapper-tests.json').read_text())
assert wrapper['tests'] == 3 and wrapper['failures'] == 0
for name, key in [('core-policy.patch', 'corePatchSha256'), ('factory-policy.patch', 'factoryPatchSha256')]:
    assert hashlib.sha256((root / 'sdk' / name).read_bytes()).hexdigest() == sdk[key], name
assert wrapper['factoryPatchSha256'] == sdk['factoryPatchSha256']
print('Evidence and false-zero guards PASS; official SDK, speaker/AEC and physical camera remain unvalidated')
