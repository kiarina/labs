#!/usr/bin/env python3
"""Check native playout, acquisition isolation, speaker observation and provenance."""
import copy
import hashlib
import json
import statistics
from pathlib import Path

root = Path(__file__).resolve().parent
read = lambda name: json.loads((root / 'results' / name).read_text())
summary, build, cleanup, human = [read(name) for name in ['summary.json', 'build.json', 'cleanup.json', 'human.json']]
expected = json.loads((root.parent / 'wrapper/validation.json').read_text())['dllSha256']


def valid(s):
    try:
        control = s['trials']['playout-default-factory']
        if control['sdkCaptureStarted'] <= 0 or control['externalOnly']:
            return False
        mf = {e['sha256'] for e in control['captureEndpoints'] if e['kind'] == 'record-mf'}
        if not mf or mf != {e['sha256'] for e in control['captureEndpoints'] if e['kind'] == 'sdk'}:
            return False
        for label, t in s['trials'].items():
            if (t['dllSha256'] != expected or t['errors'] or not t['traceLossFree']
                    or not t['captureStacksAvailable'] or not t['endpointVolumeMuteUnchanged']
                    or t['recordMfStarted'] != 1 or t['recordStarts'] != 1
                    or any(e['kind'] == 'unknown' for e in t['captureEndpoints'])):
                return False
            if any(p['delta']['rawBytes'] <= 0 or p['delta']['videoFrames'] <= 0 for p in t['phases']):
                return False
            if label != 'playout-default-factory' and (not t['externalOnly'] or t['sdkCaptureAttempts'] != 0):
                return False
            if label == 'playout-selection-initial':
                if any(w['pcmSamples'] != 0 for w in t['receiver']):
                    return False
                continue
            if t['nativePlayoutDiagnostic']:
                return False
            if not any(e['result'] == '0x00000000' and e['started'] and e['channels'] == '2' and e['rate'] == '96000' for e in t['render']):
                return False
            if len(t['receiver']) != 2 or any(w['pcmSamples'] <= 0 or w['rms'] <= 0 or w['videoFrames'] <= 0 for w in t['receiver']):
                return False
            if t['receiver'][1]['audioPacketsReceived'] <= t['receiver'][0]['audioPacketsReceived']:
                return False
            if len(t['stops']) != 2 or any(w['rms'] != 0 for w in t['stops']):
                return False
            if any(p['delta']['injectedAudio'] != 0 or p['delta']['injectedVideo'] != 0 for p in t['phases'] if p['name'].startswith('idle-after-')):
                return False
        pilot = s['trials']['playout-speaker-pilot']
        if not pilot['pilotTone'] or pilot['selectedEndpointSha256'] != s['loopback']['metadata']['endpointSha256']:
            return False
        for w in s['loopback']['windows']:
            if w['bins'] < 3 or (w['state'] == 'on' and w['medianPilotAmplitude'] < .01) or (w['state'] == 'off' and w['maxPilotAmplitude'] > .001):
                return False
        for label, prefix in [('playout-track-gates', 'native-track-'), ('playout-replace-gates', 'native-replace-')]:
            if s['trials'][label]['nativeTransitions'] != [prefix + action + '-' + str(cycle) for cycle in [1, 2] for action in ['enable', 'disable']]:
                return False
        return True
    except (KeyError, TypeError):
        return False


assert valid(summary)
for failure in ['lost', 'capture', 'no-render', 'no-pcm', 'wrong-endpoint', 'no-speaker-signal']:
    bad = copy.deepcopy(summary)
    t = bad['trials']['playout-public-selected']
    if failure == 'lost': t['traceLossFree'] = False
    if failure == 'capture': t['sdkCaptureAttempts'] = 1
    if failure == 'no-render': t['render'] = []
    if failure == 'no-pcm': t['receiver'][1]['pcmSamples'] = 0
    if failure == 'wrong-endpoint': bad['loopback']['metadata']['endpointSha256'] = '0' * 64
    if failure == 'no-speaker-signal': bad['loopback']['windows'][0]['medianPilotAmplitude'] = 0
    assert not valid(bad), failure
rows = [json.loads(line) for line in (root / 'results/loopback.jsonl').read_text().splitlines()]
assert hashlib.sha256((root / 'results/loopback.jsonl').read_bytes()).hexdigest() == summary['loopback']['inputSha256']
for window in summary['loopback']['windows']:
    values = [row['pilotAmplitude'] for row in rows[1:] if window['startUtcMs'] <= row['utcMs'] <= window['endUtcMs']]
    assert len(values) == window['bins'] and statistics.median(values) == window['medianPilotAmplitude']
assert build['dllSha256'] == expected
assert build['mainDartSha256'] == hashlib.sha256((root / 'main.dart').read_bytes()).hexdigest()
assert build['currentAotSha256'] != build['previousAotSha256']
assert human['heardBursts'] == human['expectedBursts'] == 2
assert cleanup['dedicatedTasksRemaining'] == cleanup['appProcessesRemaining'] == cleanup['loopbackProcessesRemaining'] == 0
assert cleanup['wprNotRecording']
print('Normal native render/PCM, continuous capture, SDK zero, audible speaker and six rejection guards PASS')
