#!/usr/bin/env python3
"""Extend a pinned, audited SDK using its object cache as read-only input.

No source/object/DLL in --sdk-root is modified. Two wrapper files and one native audio-state file are copied
and compiled in --output; Ninja's expanded compilation database supplies the
original toolchain and link inputs. Bootstrap the SDK with this lab's copied
patches/windows/build_sdk.ps1 if a compatible cache is unavailable.
"""
import argparse, ctypes, json, pathlib, re, subprocess, hashlib, os
p=argparse.ArgumentParser();p.add_argument('--sdk-root',required=True);p.add_argument('--output',required=True)
a=p.parse_args();sdk=pathlib.Path(a.sdk_root).resolve();out=pathlib.Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True)
source=sdk/'src';cache=source/'out-isolated';ninja=source/'third_party/ninja/ninja.exe'
manifest=json.loads((sdk/'sdk-manifest.json').read_text(encoding='utf-8-sig'))
if manifest['nativeSource']!='51c367e209f8f12b39bd8dd0ca70bf588f42cb48' or manifest['wrapperSource']!='070aa6d763c16027ba53c0965107658c837a4dae':raise SystemExit('Unexpected SDK cache source pins')
old_sha=hashlib.sha256((cache/'libwebrtc.dll').read_bytes()).hexdigest()
if old_sha!=manifest['sdkSha256']:raise SystemExit('Source SDK binary differs from its manifest')

def run(argv,**kw):
 return subprocess.run(argv,check=True,**kw)
def ninja_json(rule):
 return json.loads(run([str(ninja),'-C',str(cache),'-t','compdb','-x',rule],capture_output=True,text=True).stdout)
def windows_argv(command):
 shell=ctypes.windll.shell32;argc=ctypes.c_int();shell.CommandLineToArgvW.restype=ctypes.POINTER(ctypes.c_wchar_p)
 shell.CommandLineToArgvW.argtypes=[ctypes.c_wchar_p,ctypes.POINTER(ctypes.c_int)]
 ptr=shell.CommandLineToArgvW(command,ctypes.byref(argc));result=[ptr[i] for i in range(argc.value)];free=ctypes.windll.kernel32.LocalFree;free.argtypes=[ctypes.c_void_p];free.restype=ctypes.c_void_p;free(ptr);return result

def patched(name):
 text=((source/'audio'/name) if name=='audio_state.cc' else (source/'libwebrtc/src'/name)).read_text()
 if name=='rtc_peerconnection_factory_impl.h':
  anchor='  webrtc::Thread* signaling_thread() { return signaling_thread_.get(); }'
  assert text.count(anchor)==1
  text=text.replace(anchor,anchor+'\n  int PullExternalPlayout(int16_t* output, int samples);')
 elif name=='rtc_peerconnection_factory_impl.cc':
  text+='''
namespace libwebrtc {
int RTCPeerConnectionFactoryImpl::PullExternalPlayout(int16_t* output, int samples) {
  if (!output || samples != 480 || !audio_transport_factory_) return -1;
  auto* transport = audio_transport_factory_->audio_transport_impl();
  if (!transport) return -2;
  size_t produced = 0;
  int64_t elapsed = 0, ntp = 0;
  const int status = transport->NeedMorePlayData(480, 2, 1, 48000, output,
                                              produced, &elapsed, &ntp);
  return status == 0 ? static_cast<int>(produced) : status;
}
}
extern "C" __declspec(dllexport) int LabPullPlayout(void* factory, int16_t* output, int samples) {
  if (!factory) return -3;
  auto* base = static_cast<libwebrtc::RTCPeerConnectionFactory*>(factory);
  return static_cast<libwebrtc::RTCPeerConnectionFactoryImpl*>(base)->PullExternalPlayout(output, samples);
}
'''
 elif name=='audio_state.cc':
  anchor='  if (!receiving_streams_.empty() && !playout_enabled_) {'
  assert text.count(anchor)==1
  text=text.replace('namespace webrtc {','extern \"C\" bool ExternalCaptureRecordingAllowed();\n\nnamespace webrtc {',1)
  text=text.replace(anchor,'  if (ExternalCaptureRecordingAllowed() && !receiving_streams_.empty() && !playout_enabled_) {')
 elif name=='rtc_peerconnection_impl.cc':
  anchor='    rtc_peerconnection_->SetAudioRecording(false);'
  assert text.count(anchor)==1
  text=text.replace(anchor,anchor+'\n    // A dedicated WASAPI render thread owns the only mixer pull clock.\n    rtc_peerconnection_->SetAudioPlayout(false);')
 target=out/name;target.write_text(text);return target

for name in ['rtc_peerconnection_factory_impl.h','rtc_peerconnection_factory_impl.cc','rtc_peerconnection_impl.cc','audio_state.cc']:patched(name)
commands=ninja_json('cxx');replacements={}
for stem in ['rtc_peerconnection_factory_impl','rtc_peerconnection_impl','audio_state']:
 suffix=('/audio/' if stem=='audio_state' else '/libwebrtc/src/')+stem+'.cc'
 entry=next(x for x in commands if x['file'].replace('\\','/').endswith(suffix))
 argv=windows_argv(entry['command']);argv[0]=str((cache/argv[0]).resolve());new=[];old_obj=None
 for arg in argv:
  if arg.startswith('/showIncludes'):continue
  if arg.replace('\\','/').endswith(suffix):new.append(str(out/(stem+'.cc')))
  elif arg.startswith('/Fo'):
   old_obj=arg[3:];new.append('/Fo'+str(out/(stem+'.obj')))
  elif arg.startswith('/Fd'):new.append('/Fd'+str(out/(stem+'.pdb')))
  elif arg.startswith('-fcrash-diagnostics-dir='):new.append('-fcrash-diagnostics-dir='+str(out/'crashreports'))
  else:new.append(arg)
 # Quoted includes in copied source resolve the copied factory header first;
 # other wrapper implementation headers remain read-only cache inputs.
 new.extend(['-I'+str(source/'libwebrtc/src')])
 run(new,cwd=cache)
 replacements[old_obj.replace('\\','/')]=str(out/(stem+'.obj'))
def expand_rsp_arguments(arguments):
 result=[]
 for item in arguments:
  if 'obj/' in item.replace('\\','/') and ' ' in item:result.extend(windows_argv(item))
  else:result.append(item)
 return result

def clone_archive(relative, old_object, new_object):
 entry=next(x for x in ninja_json('alink') if x['output'].replace('\\','/')==relative)
 arguments=windows_argv(entry['command']);binary=str((cache/arguments.pop(0)).resolve());arguments=expand_rsp_arguments(arguments)
 output=out/pathlib.Path(relative).name;rewritten=[];count=0
 for item in arguments:
  if item.replace('\\','/')==old_object:rewritten.append(new_object);count+=1
  elif item.upper().startswith('/OUT:'):rewritten.append('/OUT:'+str(output))
  else:rewritten.append(item)
 if count!=1:raise SystemExit(f'Archive member not found exactly once: {old_object}')
 rewritten=[item for item in rewritten if item.lower()!='/lib']
 response=out/(output.name+'.rsp');response.write_text(subprocess.list2cmdline(rewritten))
 run([binary,'/lib','@'+str(response)],cwd=cache)
 return str(output)

link=next(x for x in ninja_json('solink') if 'libwebrtc.dll' in x['output'])
argv=windows_argv(link['command']);binary=str((cache/argv.pop(0)).resolve());argv=expand_rsp_arguments(argv)
audio_object=next(x for x in replacements if x.endswith('/audio_state.obj'))
archive=next((x for x in argv if x.replace('\\','/') in ('obj/audio/audio.lib','obj/webrtc.lib')),None)
if archive is None:raise SystemExit('AudioState archive is missing from link inputs')
replacements[archive.replace('\\','/')]=clone_archive(archive.replace('\\','/'),audio_object,replacements.pop(audio_object))
new=[];replacement_count=0
for arg in argv:
 normalized=arg.replace('\\','/')
 if normalized in replacements:new.append(replacements[normalized]);replacement_count+=1
 elif arg.upper().startswith('/OUT:'):new.append('/OUT:'+str(out/'libwebrtc.dll'))
 elif arg.upper().startswith('/PDB:'):new.append('/PDB:'+str(out/'libwebrtc.dll.pdb'))
 elif arg.upper().startswith('/IMPLIB:'):new.append('/IMPLIB:'+str(out/'libwebrtc.dll.lib'))
 else:new.append(arg)
if replacement_count!=3:raise SystemExit(f'Expected three object replacements, found {replacement_count}')
rsp=out/'link.rsp';rsp.write_text(subprocess.list2cmdline(new))
run([binary,'@'+str(rsp)],cwd=cache)
if hashlib.sha256((cache/'libwebrtc.dll').read_bytes()).hexdigest()!=old_sha:raise SystemExit('Unexpected change to source SDK')
result={'sourceSdkSha256':old_sha,'sdkSha256':hashlib.sha256((out/'libwebrtc.dll').read_bytes()).hexdigest(),'nativeSource':manifest['nativeSource'],'wrapperSource':manifest['wrapperSource'],'recordingSuppressionRetained':True,'nativePlayoutDisabled':True,'nativeNullPollerDisabled':True,'manualPlayoutExport':'LabPullPlayout','cachedObjectInputsReadOnly':True}
(out/'sdk-manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
