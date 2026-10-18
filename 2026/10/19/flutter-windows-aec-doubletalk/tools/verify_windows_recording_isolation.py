#!/usr/bin/env python3
"""Check device isolation and received media against a same-DLL positive control."""
import argparse
import json
import pathlib
import re
from verify_results import check as check_media

COUNTERS = (
    'admInitRecording', 'admStartRecording', 'windowsInitRecording',
    'windowsStartRecording', 'wasapiInitialize', 'wasapiCaptureService',
    'dmoInitRecording', 'peerConnections', 'suppressedPeerConnections',
)

def check_pair(protected_path, control_path):
    errors = []
    def require(condition, message):
        if not condition:
            errors.append(message)
    reports = []
    for label, path in [('protected', protected_path), ('control', control_path)]:
        report = json.loads(path.read_text())
        report = report.get('result', report)
        reports.append(report)
        audit = report.get('recordingAudit', {})
        require(all(isinstance(audit.get(key), int) and not isinstance(audit.get(key), bool)
                    and audit[key] >= 0 for key in COUNTERS), label + ': missing/invalid audit export results')
        require(bool(re.fullmatch('[0-9a-fA-F]{64}', report.get('sdkSha256', ''))), label + ': missing SDK SHA256')
    protected, control = reports
    if errors:
        return errors
    require(protected.get('synthetic') is False, 'protected run must use the real record microphone')
    require(protected.get('receiver') == 'independent-chromium', 'protected receiver must be independent Chromium')
    require(protected.get('sources', {}).get('audio') == 'record-microphone', 'protected audio source must be record-microphone')
    require(protected['sdkSha256'].lower() == control['sdkSha256'].lower(), 'control uses a different SDK DLL')
    require(protected.get('recordingControl') is False, 'protected run must report recording control disabled')
    require(control.get('recordingControl') is True, 'control run must report recording control enabled')
    audit = protected['recordingAudit']
    require(audit['peerConnections'] > 0, 'no protected peer connections exercised')
    require(audit['peerConnections'] == audit['suppressedPeerConnections'], 'not all protected peers disable recording')
    for key in COUNTERS[:7]:
        require(audit[key] == 0, 'protected: recording path called: ' + key)
    baseline = control['recordingAudit']
    require(baseline['peerConnections'] > 0, 'no control peer connections exercised')
    require(baseline['suppressedPeerConnections'] == 0, 'positive control still suppresses recording')
    require(baseline['admInitRecording'] > 0 and baseline['windowsInitRecording'] > 0,
            'positive control did not exercise the ADM and Windows capture initialization')
    require(baseline['wasapiInitialize'] > 0 or baseline['dmoInitRecording'] > 0,
            'positive control did not reach either physical capture initialization route')
    errors.extend('protected media: ' + error for error in check_media(protected_path))
    return errors

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('protected', type=pathlib.Path)
    parser.add_argument('control', type=pathlib.Path)
    args = parser.parse_args()
    errors = check_pair(args.protected, args.control)
    print('\n'.join(errors) if errors else 'PASS: same SDK; control reaches capture; protected recording calls=0; capture and remote media continue')
    raise SystemExit(bool(errors))
