"""The audit verifier must fail closed when evidence is missing or contradictory."""
import copy
import json
import pathlib
import tempfile
import unittest
from verify_windows_recording_isolation import COUNTERS, check_pair

class RecordingVerifierTest(unittest.TestCase):
    def setUp(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        self.protected = json.loads((root / 'results/windows-browser-record-profile-cleanup.json').read_text())
        self.protected.update(sdkSha256='a' * 64, recordingControl=False)
        self.protected['recordingAudit'] = dict.fromkeys(COUNTERS, 0)
        self.protected['recordingAudit'].update(peerConnections=1, suppressedPeerConnections=1)
        self.control = copy.deepcopy(self.protected)
        self.control.update(recordingControl=True)
        self.control['recordingAudit'].update(admInitRecording=2, windowsInitRecording=2,
                                             dmoInitRecording=2, suppressedPeerConnections=0)

    def check(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [pathlib.Path(directory) / name for name in ('protected.json', 'control.json')]
            for path, report in zip(paths, (self.protected, self.control)):
                path.write_text(json.dumps(report))
            return check_pair(*paths)

    def test_positive_evidence(self):
        self.assertEqual(self.check(), [])

    def test_synthetic_capture_rejected(self):
        self.protected.update(synthetic=True)
        self.protected['captureStarts']['microphone'] = 0
        self.protected['sources']['audio'] = 'synthetic-pcm440hz'
        self.assertTrue(self.check())

    def test_receiver_must_be_independent(self):
        self.protected['receiver'] = 'same-process-loopback'
        self.assertTrue(self.check())

    def test_missing_export_is_not_zero(self):
        del self.protected['recordingAudit']
        self.assertTrue(self.check())

    def test_extra_capture_call_rejected(self):
        self.protected['recordingAudit']['wasapiInitialize'] = 1
        self.assertTrue(self.check())

    def test_different_dll_rejected(self):
        self.control['sdkSha256'] = 'b' * 64
        self.assertTrue(self.check())

    def test_unexercised_control_rejected(self):
        self.control['recordingAudit'].update(admInitRecording=0, windowsInitRecording=0, dmoInitRecording=0)
        self.assertTrue(self.check())

    def test_old_audio_concealment_is_not_new_rtp(self):
        for phase in self.protected['phases']:
            if phase['name'].startswith('send-'):
                phase['receiverDelta']['audioBytes'] = 0
        self.assertTrue(self.check())

    def test_silent_external_input_rejected(self):
        for phase in self.protected['phases']:
            if phase['name'].startswith('send-'):
                phase['receiverDelta']['audioRmsMax'] = 0
        self.assertTrue(self.check())

if __name__ == '__main__':
    unittest.main()
