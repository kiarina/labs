#!/usr/bin/env python3
"""Assess native playout experiments; private inputs contain no saved PCM."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import statistics

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('evidence', type=Path)
p.add_argument('loopback', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parent
expected = json.loads((root.parent / 'wrapper/validation.json').read_text())['dllSha256']
read = lambda f: json.loads(f.read_text(encoding='utf-8-sig'))
modules = lambda e: {f.get('module', '').lower() for f in e.get('stack', [])}
trials = {}
for label in ['playout-selection-initial', 'playout-public-selected', 'playout-default-factory',
              'playout-track-gates', 'playout-replace-gates', 'playout-speaker-pilot']:
    folder = a.evidence / label
    app, etw, policy = [read(folder / name) for name in ['upstream_input_result.json', 'normalized.json', 'trial-policy.json']]
    assert app['sdkIdentity']['sha256'] == expected
    capture = [e for e in etw['events'] if e['event'] == 'AudioClientInitialize' and e['data'].get('StreamType') == '1']
    render = etw['renderInitializeEvents']
    started = {e['data'].get('AudioClientGuidId') for e in etw['events'] if e['event'] == 'AudioClientStart' and e['data'].get('HResult') == '0x00000000'}
    selected = app.get('publicPlayoutSelection') or app.get('playoutSelection')
    trials[label] = {
        'dllSha256': expected, 'errors': app['errors'], 'externalOnly': policy['externalOnly'],
        'nativePlayoutDiagnostic': app.get('nativePlayoutDiagnostic'), 'pilotTone': app.get('pilotTone', False),
        'sourceRms': app['sourceRms'], 'recordStarts': app['captureStarts']['record'],
        'traceLossFree': etw['lostEvents'] == etw['lostBuffers'] == 0,
        'captureStacksAvailable': all(e.get('stack') for e in capture),
        'sdkCaptureAttempts': sum('libwebrtc.dll' in modules(e) for e in capture),
        'recordMfStarted': sum('mfcore.dll' in modules(c['initialize']) and 'libwebrtc.dll' not in modules(c['initialize']) for c in etw['captureStartedClients']),
        'sdkCaptureStarted': etw['sdkCaptureStartedClients'],
        'captureEndpoints': [{'kind': 'sdk' if 'libwebrtc.dll' in modules(e) else 'record-mf' if 'mfcore.dll' in modules(e) else 'unknown', 'sha256': e['data'].get('EndpointIdSha256')} for e in capture],
        'render': [{'result': e['data'].get('HResult'), 'channels': e['data'].get('NumberOfChannels'), 'rate': e['data'].get('SampleRate'), 'started': e['data'].get('AudioClientGuidId') in started, 'endpointSha256': e['data'].get('EndpointIdSha256')} for e in render],
        'receiver': [{'pcmSamples': w['pcmSamples'], 'rms': w['rms'], 'videoFrames': w['videoFrames'], 'audioPacketsReceived': sum(int(float(s.get('packetsReceived', 0))) for s in w['inbound'] if s.get('kind') == 'audio')} for w in app['receiver']],
        'phases': [{'name': w['name'], 'delta': w['delta']} for w in app['phases']],
        'stops': [{'rms': w['rms'], 'pcmSamples': w['pcmSamples']} for w in app.get('stopWindows', [])],
        'nativeTransitions': [w['stage'] for w in app['timeline'] if w['stage'].startswith(('native-track-', 'native-replace-'))],
        'maxAudioGapMs': app['maxAudioGapMs'], 'maxVideoGapMs': app['maxVideoGapMs'],
        'selectedSpeaker': selected.get('label', selected.get('selectedLabel')),
        'selectedEndpointSha256': hashlib.sha256(selected['deviceId'].encode()).hexdigest() if 'deviceId' in selected else None,
        'endpointVolumeMuteUnchanged': (folder / 'volume-before.txt').read_bytes() == (folder / 'volume-after.txt').read_bytes(),
        'traceInputSha256': etw['inputSha256'],
    }
rows = [json.loads(line) for line in a.loopback.read_text(encoding='utf-8-sig').splitlines()]
meta, bins = rows[0], rows[1:]
app = read(a.evidence / 'playout-speaker-pilot/upstream_input_result.json')
utc_ms = lambda text: datetime.datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp() * 1000
marks = {w['stage']: utc_ms(w['utc']) for w in app['timeline']}
windows = []
for cycle in [1, 2]:
    for state in ['on', 'off']:
        start = marks[f'send-{cycle}' if state == 'on' else f'idle-after-{cycle}'] + 1200
        end = marks[f'idle-after-{cycle}'] - 200 if state == 'on' else marks['send-2' if cycle == 1 else 'cleanup'] - 100
        values = [row['pilotAmplitude'] for row in bins if start <= row['utcMs'] <= end]
        windows.append({'cycle': cycle, 'state': state, 'startUtcMs': start, 'endUtcMs': end, 'bins': len(values), 'medianPilotAmplitude': statistics.median(values) if values else None, 'maxPilotAmplitude': max(values) if values else None})
result = {'dllSha256': expected, 'sdkChanged': False, 'normalNativePlayout': True,
          'physicalCameraValidated': False, 'aecValidated': False,
          'trials': trials, 'loopback': {'metadata': meta, 'windows': windows,
          'inputSha256': hashlib.sha256(a.loopback.read_bytes()).hexdigest()}}
a.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'trials': len(trials), 'loopback': windows}))
