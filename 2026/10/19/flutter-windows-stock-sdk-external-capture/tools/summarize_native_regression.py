#!/usr/bin/env python3
"""Normalize gtest JSON from candidate and same-harness guard-restored control."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('input', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]


def load(name):
    data = json.loads((args.input / name).read_text())
    cases = {suite['name'] + '.' + case['name']: case
             for suite in data['testsuites'] for case in suite['testsuite']}
    assert len(cases) == data['tests'] and cases, name
    assert all(case['status'] == 'RUN' for case in cases.values()), name
    failed = {name for name, case in cases.items() if case.get('failures')}
    assert len(failed) == data['failures'], name
    return cases, failed


report = {
    'nativeCommit': '51c367e209f8f12b39bd8dd0ca70bf588f42cb48',
    'patchSha256': hashlib.sha256((root / 'upstream/02-recording-policy.patch').read_bytes()).hexdigest(),
    'platform': 'Windows x64, Visual Studio 2022, Chromium Clang',
    'control': 'same candidate test harness/getter; all three production guards reverted; not a pristine upstream binary',
    'buildPassed': True,
    'groups': {},
    'deviceCaptureValidated': False,
    'wrapperValidated': False,
    'upstreamPRCreated': False,
}
for prefix in ['audio-state', 'voice-engine']:
    candidate, cf = load(prefix + '-candidate.json')
    baseline, bf = load(prefix + '-baseline.json')
    assert candidate.keys() == baseline.keys(), 'Different test populations'
    assert not cf - bf, 'New failing tests'
    common = sorted(cf & bf)
    report['groups'][prefix] = {
        'tests': len(candidate), 'candidatePassed': len(candidate) - len(cf),
        'candidateFailed': len(cf), 'controlFailed': len(bf),
        'newFailures': sorted(cf - bf), 'repaired': sorted(bf - cf),
        'commonFailureNamesSha256': hashlib.sha256(('\n'.join(common) + '\n').encode()).hexdigest(),
        'commonFailureExamples': common[:3],
    }
    if prefix == 'audio-state':
        assert len(candidate) == 60 and not cf and len(bf) == 4
    else:
        focus = {name: case for name, case in candidate.items() if any(
            part in name for part in ['DisabledRecording', 'EnabledRecordingStill',
                                      'InitRecordingOnSend', 'SkipInitRecordingOnSend'])}
        assert len(focus) == 10 and not any(case.get('failures') for case in focus.values())
        assert len(bf - cf) == 4
        report['focusedVoiceTestsPassed'] = sorted(focus)
report['allTestsPassed'] = all(not group['candidateFailed'] for group in report['groups'].values())
args.output.write_text(json.dumps(report, indent=2) + '\n')
print('Recorded native comparison; allTestsPassed=' + str(report['allTestsPassed']))
