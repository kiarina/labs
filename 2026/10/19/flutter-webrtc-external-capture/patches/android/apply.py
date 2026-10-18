#!/usr/bin/env python3
"""Apply only Android lab hooks to a local flutter_webrtc 1.6.2+hotfix.4 copy."""
import pathlib
import shutil
import sys
root = pathlib.Path(sys.argv[1])
java = root / 'android/src/main/java/com/cloudwebrtc/webrtc'
p = java / 'MethodCallHandlerImpl.java'
s = p.read_text()
if 'externalCapture = new ExternalCapture' in s:
    shutil.copyfile(pathlib.Path(__file__).with_name('ExternalCapture.java'), java / 'ExternalCapture.java')
    raise SystemExit(0)
def replace_once(old, new):
    global s
    if s.count(old) != 1:
        raise SystemExit(f'Unexpected upstream source: {old}')
    s = s.replace(old, new, 1)
replace_once('  private PeerConnectionFactory mFactory;', '  private PeerConnectionFactory mFactory;\n  private final ExternalCapture externalCapture = new ExternalCapture(this);')
replace_once('    this.messenger = messenger;', '    this.messenger = messenger;\n    new io.flutter.plugin.common.MethodChannel(messenger, "external_capture")\n        .setMethodCallHandler(externalCapture);')
replace_once('    audioDeviceModule = audioDeviceModuleBuilder.createAudioDeviceModule();', '''    audioDeviceModuleBuilder.setInputSampleRate(48000).setUseStereoInput(false)
        .setUseHardwareAcousticEchoCanceler(false).setUseHardwareNoiseSuppressor(false)
        .setAudioBufferCallback(externalCapture);
    audioDeviceModule = audioDeviceModuleBuilder.createAudioDeviceModule();
    audioDeviceModule.setAudioRecordEnabled(false);''')
p.write_text(s)
shutil.copyfile(pathlib.Path(__file__).with_name('ExternalCapture.java'), java / 'ExternalCapture.java')
