#!/usr/bin/env python3
"""Patch the pinned native WebRTC + libwebrtc wrapper for Windows isolation.

Invoke after applying upstream libwebrtc m150 patches, before GN/Ninja.
An EXTERNAL_CAPTURE_RECORDING_CONTROL=1 environment variable restores normal
recording behavior for the positive control using the same audited DLL.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1])

def edit(relative, old, new):
    p = root / relative
    text = p.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f'{relative}: expected exactly one patch anchor: {old!r}')
    p.write_text(text.replace(old, new))

audit = '''
// Lab-only, process-wide audit. Counters instrument the WebRTC DLL only;
// record_windows is a separate capture implementation and is not counted.
#include <atomic>
#include <array>
#include <cstdint>
#include <cstdlib>
extern "C" bool ExternalCaptureRecordingAllowed() {
  const char* control = std::getenv("EXTERNAL_CAPTURE_RECORDING_CONTROL");
  return control && control[0] == '1';
}
static std::array<std::atomic<uint64_t>, 9> g_external_capture_audit{};
extern "C" __declspec(dllexport) void ExternalCaptureAuditIncrement(int index) {
  if (index >= 0 && index < 9) ++g_external_capture_audit.at(static_cast<size_t>(index));
}
extern "C" __declspec(dllexport) uint64_t ExternalCaptureGetRecordingAudit(int index) {
  if (index < 0 || index >= 9) return UINT64_MAX;
  return g_external_capture_audit.at(static_cast<size_t>(index)).load();
}
'''
# Migrate the earlier lab-only pointer-output audit ABI if resuming its build.
audit_path = root / 'modules/audio_device/audio_device_impl.cc'
audit_text = audit_path.read_text()
if 'static std::atomic<uint64_t> g_external_capture_audit[9]' in audit_text:
    start = audit_text.index('// Lab-only, process-wide audit.')
    end = audit_text.index('namespace webrtc {', start)
    audit_path.write_text(audit_text[:start] + audit_text[end:])
edit('modules/audio_device/audio_device_impl.cc', 'namespace webrtc {', audit + '\nnamespace webrtc {')
for method, index in [('InitRecording', 0), ('StartRecording', 1)]:
    anchor = f'int32_t AudioDeviceModuleImpl::{method}() {{'
    edit('modules/audio_device/audio_device_impl.cc', anchor,
         anchor + f'\n  ExternalCaptureAuditIncrement({index});')

proto = 'extern "C" void ExternalCaptureAuditIncrement(int index);\n'
edit('modules/audio_device/win/audio_device_core_win.cc', 'namespace webrtc {', proto + '\nnamespace webrtc {')
for method, index in [('InitRecording', 2), ('StartRecording', 3), ('InitRecordingDMO', 6)]:
    anchor = f'int32_t AudioDeviceWindowsCore::{method}() {{'
    edit('modules/audio_device/win/audio_device_core_win.cc', anchor,
         anchor + f'\n  ExternalCaptureAuditIncrement({index});')
for anchor, index in [('  hr = _ptrClientIn->Initialize(', 4), ('  hr = _ptrClientIn->GetService(__uuidof(IAudioCaptureClient),', 5)]:
    edit('modules/audio_device/win/audio_device_core_win.cc', anchor,
         f'  ExternalCaptureAuditIncrement({index});\n' + anchor)

pc = 'libwebrtc/src/rtc_peerconnection_impl.cc'
edit(pc, '#include "rtc_peerconnection_impl.h"', '#include "rtc_peerconnection_impl.h"\n#include <cstdlib>\n' + proto)
anchor = '  rtc_peerconnection_ = result.MoveValue();'
edit(pc, anchor, anchor + '''
  ExternalCaptureAuditIncrement(7);
  const char* recording_control = std::getenv("EXTERNAL_CAPTURE_RECORDING_CONTROL");
  if (!(recording_control && recording_control[0] == '1')) {
    // Must precede AddTrack / SDP so no native recording is initialized.
    rtc_peerconnection_->SetAudioRecording(false);
    ExternalCaptureAuditIncrement(8);
  }
''')

# SetAudioRecording(false) must guard initialization too: native WebRTC's
# AudioState otherwise initializes capture before checking recording_enabled_.
edit('audio/audio_state.cc', '\n  if (!adm->Recording()) {',
     '\n  if (recording_enabled_ && !adm->Recording()) {')

# VoiceSendChannel's separate eager initialization path consumes source options.
# Preserve the ordinary default for the positive-control run.
source = 'libwebrtc/src/rtc_peerconnection_factory_impl.cc'
edit(source, '#include "rtc_peerconnection_factory_impl.h"',
     '#include "rtc_peerconnection_factory_impl.h"\n#include <cstdlib>')
anchor = '  rtc_options.highpass_filter = options.highpass_filter;'
edit(source, anchor, anchor + '''
  const char* recording_control = std::getenv("EXTERNAL_CAPTURE_RECORDING_CONTROL");
  if (source_type == RTCAudioSource::SourceType::kCustom &&
      !(recording_control && recording_control[0] == '1')) {
    rtc_options.init_recording_on_send = false;
  }
''')

# A second capture start path exists when stop-on-mute mode is enabled.
voice = 'media/engine/webrtc_voice_engine.cc'
edit(voice, 'namespace webrtc {',
     'extern "C" bool ExternalCaptureRecordingAllowed();\n\nnamespace webrtc {')
edit(voice, '    if (options_.init_recording_on_send.value_or(true) &&',
     '    if (ExternalCaptureRecordingAllowed() &&\n        options_.init_recording_on_send.value_or(true) &&')
edit(voice, '      if (adm) {',
     '      if (ExternalCaptureRecordingAllowed() && adm) {')

print('Applied Windows recording isolation + nine audit counters')
