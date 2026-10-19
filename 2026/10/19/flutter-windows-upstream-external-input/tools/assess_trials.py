#!/usr/bin/env python3
"""Assess candidate DLL trials using independently observed capture and controls."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('trials', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
expected = json.loads((root / 'results/candidate-sdk.json').read_text())


def read(folder, name):
    return json.loads((folder / name).read_text(encoding='utf-8-sig'))


def assess(label):
    folder = args.trials / label
    app = read(folder, 'upstream_input_result.json')
    etw = read(folder, 'normalized.json')
    sdk = read(folder, 'sdk-manifest.json')
    policy = read(folder, 'trial-policy.json')
    assert sdk['dllSha256'] == expected['dllSha256'], 'Different candidate DLL'
    identity = app.get('sdkIdentity')
    if app['variant'] != 'record-only':
        assert identity['sha256'] == expected['dllSha256'], 'Loaded DLL mismatch'
        assert identity['customRecordingAuditExportPresent'] is False
        assert identity['customPlayoutExportPresent'] is False
    clients = {}
    for event in etw['events']:
        data = event['data']
        if event['event'] != 'AudioClientInitialize' or data.get('StreamType') != '1':
            continue
        modules = sorted({frame['module'].lower() for frame in event.get('stack', []) if frame.get('module')})
        sdk_caller = 'libwebrtc.dll' in modules
        mf_caller = 'mfcore.dll' in modules and not sdk_caller
        clients[data['AudioClientGuidId']] = {
            'kind': 'sdk' if sdk_caller else 'record-mf' if mf_caller else 'unknown',
            'initializeSucceeded': data['HResult'] == '0x00000000',
            'started': False, 'stackAvailable': bool(event.get('stack')),
            'endpointSha256': data.get('EndpointIdSha256'), 'modules': modules,
        }
    for event in etw['events']:
        data = event['data']
        if event['event'] == 'AudioClientStart' and data.get('HResult') == '0x00000000':
            if data.get('AudioClientGuidId') in clients:
                clients[data['AudioClientGuidId']]['started'] = True
    values = list(clients.values())
    sdk_clients = [c for c in values if c['kind'] == 'sdk']
    mf = [c for c in values if c['kind'] == 'record-mf']
    receiver = app.get('receiver', [])
    audio_packets = [sum(int(float(stat.get('packetsReceived', 0))) for stat in phase.get('inbound', []) if stat.get('kind') == 'audio') for phase in receiver]
    return {
        'variant': app['variant'], 'externalOnly': policy['externalOnly'],
        'nativePlayoutDiagnostic': app.get('nativePlayoutDiagnostic'),
        'dllSha256': sdk['dllSha256'], 'errors': app['errors'],
        'lateModeChangeRejected': app.get('lateModeChangeRejected'),
        'traceLossFree': etw.get('lostEvents') == 0 and etw.get('lostBuffers') == 0,
        'allCaptureStacksAvailable': all(c['stackAvailable'] for c in values),
        'sdkCaptureAttempts': len(sdk_clients),
        'sdkCaptureInitialized': sum(c['initializeSucceeded'] for c in sdk_clients),
        'sdkCaptureStarted': sum(c['initializeSucceeded'] and c['started'] for c in sdk_clients),
        'recordCaptureStarted': sum(c['initializeSucceeded'] and c['started'] for c in mf),
        'unknownCaptureClients': sum(c['kind'] == 'unknown' for c in values),
        'captureClients': values,
        'singleRecordContinuity': app['captureStarts']['record'] == 1 and bool(app['phases']) and all(
            ph['delta']['rawBytes'] > 0 and ph['delta']['videoFrames'] > 0 for ph in app['phases']),
        'sourceRms': app['sourceRms'], 'physicalCameraValidated': False,
        'receiver': [{'gate': phase['gate'], 'pcmSamples': phase['pcmSamples'], 'rms': phase['rms'], 'videoFrames': phase['videoFrames'], 'audioPacketsReceived': audio_packets[i]} for i, phase in enumerate(receiver)],
        'totals': app['totals'],
        'maxAudioGapMs': app['maxAudioGapMs'], 'maxVideoGapMs': app['maxVideoGapMs'],
        'capturePhaseDeltas': [{'name': phase['name'], 'delta': phase['delta']} for phase in app['phases']],
        'nativeTrackTransitions': [entry['stage'] for entry in app['timeline'] if entry['stage'].startswith(('native-track-', 'native-replace-'))],
        'videoSource': app['videoSource'],
        'audioRtpReceived': bool(receiver) and all(any(s.get('kind') == 'audio' and float(s.get('packetsReceived', 0)) > 0 for s in phase.get('inbound', [])) for phase in receiver),
        'audioRtpAdvancedAcrossGates': len(audio_packets) == 2 and audio_packets[0] > 0 and audio_packets[1] > audio_packets[0],
        'audioDecoded': bool(receiver) and all(phase.get('pcmSamples', 0) > 0 for phase in receiver),
        'videoDecoded': bool(receiver) and all(phase.get('videoFrames', 0) > 0 for phase in receiver),
        'functionalTransportPass': app['functionalTransportPass'],
        'renderInitializeEvents': etw.get('renderInitializeEvents'),
        'endpointVolumeMuteUnchanged': (folder / 'volume-before.txt').read_bytes() == (folder / 'volume-after.txt').read_bytes(),
        'traceInputSha256': etw.get('inputSha256'),
    }


labels = ['record-only', 'native-mic-default', 'external-default', 'external-only']
for optional in ['external-muted', 'external-native-playout-off', 'external-track-gates-playout-off', 'external-replace-gates-playout-off']:
    if (args.trials / optional / 'sdk-manifest.json').exists():
        labels.append(optional)
trials = {label: assess(label) for label in labels}
controls = (
    all(t['traceLossFree'] and t['allCaptureStacksAvailable'] and t['endpointVolumeMuteUnchanged'] and not t['unknownCaptureClients'] for t in trials.values())
    and trials['record-only']['recordCaptureStarted'] == 1
    and trials['record-only']['sdkCaptureAttempts'] == 0
    and trials['native-mic-default']['sdkCaptureStarted'] == 1
    and trials['native-mic-default']['externalOnly'] is False
    and trials['external-default']['sdkCaptureStarted'] == 1
    and trials['external-default']['recordCaptureStarted'] == 1
    and trials['external-default']['externalOnly'] is False
)
ext = trials['external-only']
zero = controls and ext['externalOnly'] is True and ext['recordCaptureStarted'] == 1 and ext['sdkCaptureAttempts'] == 0 and ext['singleRecordContinuity'] and not ext['errors'] and ext['audioRtpAdvancedAcrossGates'] and ext['videoDecoded'] and ext['sourceRms'] > 1e-6
result = {
    'kind': 'candidate-native-external-input-validation',
    'sdk': expected, 'controlsValid': controls,
    'captureIsolationPass': zero,
    'mediaFlowPass': ext['functionalTransportPass'] and ext['audioDecoded'] and ext['videoDecoded'],
    'officialSdkValidated': False, 'aecValidated': False,
    'physicalWindowsCameraValidated': False, 'upstreamPRCreated': False,
    'trials': trials,
}
record_endpoints = {c['endpointSha256'] for c in trials['record-only']['captureClients']}
sdk_endpoints = {c['endpointSha256'] for c in trials['native-mic-default']['captureClients'] if c['kind'] == 'sdk'}
result['sameCaptureEndpointControls'] = bool(record_endpoints and record_endpoints == sdk_endpoints)
result['controlsValid'] = controls and result['sameCaptureEndpointControls']
result['captureIsolationPass'] = zero and result['controlsValid']
for label in ['external-muted', 'external-native-playout-off', 'external-track-gates-playout-off', 'external-replace-gates-playout-off']:
    if label not in trials:
        continue
    trial = trials[label]
    trial['captureIsolationPass'] = bool(result['controlsValid'] and trial['traceLossFree'] and trial['endpointVolumeMuteUnchanged'] and trial['externalOnly'] and trial['singleRecordContinuity'] and trial['recordCaptureStarted'] == 1 and trial['sdkCaptureAttempts'] == 0 and trial['unknownCaptureClients'] == 0 and not trial['errors'] and trial['audioRtpAdvancedAcrossGates'] and trial['videoDecoded'] and trial['sourceRms'] > 1e-6)
if 'external-native-playout-off' in trials:
    diagnostic = trials['external-native-playout-off']
    result['diagnosticDecodedMediaPass'] = bool(diagnostic['captureIsolationPass'] and diagnostic['audioDecoded'] and diagnostic['videoDecoded'] and diagnostic['functionalTransportPass'])
    result['publicWrapperPlayoutApiValidated'] = False
if 'external-track-gates-playout-off' in trials:
    gates = trials['external-track-gates-playout-off']
    result['nativeTrackGateDiagnosticPass'] = bool(gates['captureIsolationPass'] and gates['audioDecoded'] and gates['videoDecoded'] and gates['functionalTransportPass'])
if 'external-replace-gates-playout-off' in trials:
    replace = trials['external-replace-gates-playout-off']
    result['nativeReplaceGateDiagnosticPass'] = bool(replace['captureIsolationPass'] and replace['audioDecoded'] and replace['videoDecoded'] and replace['functionalTransportPass'])
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: v for k, v in result.items() if k not in ('sdk', 'trials')}))
