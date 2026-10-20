#!/usr/bin/env python3
"""Apply explicit opt-in RAW capture branch to pinned record_windows 2.3.0."""
import pathlib,shutil,sys
root=pathlib.Path(sys.argv[1]);here=pathlib.Path(__file__).parent

def edit(relative,old,new):
 p=root/relative;s=p.read_text()
 if new in s:return
 if s.count(old)!=1:raise RuntimeError('Unexpected source: '+relative)
 p.write_text(s.replace(old,new))

shutil.copy2(here/'raw_capture.h',root/'windows/record/raw_capture.h')
edit('windows/record/record.h','#include "recorder_dispatcher.h"','#include "recorder_dispatcher.h"\n#include "record/raw_capture.h"')
edit('windows/record/record.h','\t\tbool m_disposed = false;','\t\tbool m_disposed = false;\n\t\tstd::unique_ptr<RawCapture> m_rawCapture;')
edit('windows/record/record.cpp','namespace record_windows\n{','''namespace record_windows
{
 extern "C" __declspec(dllexport) uint64_t RecordRawAudit(int index) {
  return index>=0&&index<7?raw_audit[index].load():UINT64_MAX;
 }
''')
anchor='''\t\tconst auto& enc = config->encoderName;'''
branch='''\t\t// Explicit lab-only branch. Never initialize MF and RAW capture together.
        wchar_t rawMode[8]{};
        if (GetEnvironmentVariableW(L"AEC_RECORD_RAW", rawMode, 8) == 1 && rawMode[0] == L'1') {
            if (config->encoderName != AudioEncoder::pcm16bits ||
                config->sampleRate != 48000 || config->numChannels != 1 || config->deviceId.empty())
                return E_INVALIDARG; // RAW requires selected device, PCM16 mono48k.
            HRESULT rawHr = EndRecording();
            if (FAILED(rawHr)) return rawHr;
            m_pConfig = std::move(config);
            const auto& id = m_pConfig->deviceId;
            int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, id.data(), static_cast<int>(id.size()), nullptr, 0);
            if (count <= 0) { EndRecording(); return E_INVALIDARG; }
            std::wstring endpoint(count, L'\\0');
            MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, id.data(), static_cast<int>(id.size()), endpoint.data(), count);
            m_rawCapture = std::make_unique<RawCapture>();
            rawHr = m_rawCapture->Start(endpoint, [this](std::vector<uint8_t> bytes) {
                if (m_callbacks.onChunk) m_callbacks.onChunk(std::move(bytes));
            });
            if (FAILED(rawHr)) { EndRecording(); return rawHr; } // No MF fallback.
            UpdateState(RecordState::record);
            return S_OK;
        }
''' + anchor
edit('windows/record/record.cpp',anchor,branch)
for name in ['Pause','Resume']:
 old='\tHRESULT Recorder::'+name+'()\n\t{\n\t\tAssertOnDispatcher();'
 edit('windows/record/record.cpp',old,old+'\n        if (m_rawCapture) return E_NOTIMPL; // RAW pause/resume unsupported in this lab.')
old='\tHRESULT Recorder::EndRecording()\n\t{\n\t\tHRESULT hr = S_OK;'
edit('windows/record/record.cpp',old,old+'\n        // Join before clearing callbacks/config or allowing another acquisition.\n        if (m_rawCapture) { m_rawCapture->Stop(); m_rawCapture.reset(); }')
old='\tHRESULT Recorder::CreateAudioCaptureDevice(LPCWSTR deviceId)\n\t{'
edit('windows/record/record.cpp',old,old+'\n        raw_audit[5]++; // Media Foundation capture creation requests.')
