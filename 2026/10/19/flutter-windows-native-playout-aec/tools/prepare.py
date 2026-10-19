#!/usr/bin/env python3
"""Prepare an isolated Flutter plugin for candidate-SDK validation."""
import hashlib,io,json,pathlib,tarfile,urllib.request
root=pathlib.Path(__file__).resolve().parents[1]
target=root/'vendor/flutter_webrtc'
if target.exists(): raise SystemExit('Use a fresh vendor directory; existing work is preserved')
version='1.6.2+hotfix.4'
with urllib.request.urlopen(f'https://pub.dev/api/packages/flutter_webrtc/versions/{version}')as r: metadata=json.load(r)
with urllib.request.urlopen(metadata['archive_url'])as r: archive=r.read()
assert hashlib.sha256(archive).hexdigest()==metadata['archive_sha256']
target.mkdir(parents=True)
with tarfile.open(fileobj=io.BytesIO(archive),mode='r:gz')as tf:tf.extractall(target,filter='data')

def replace(name,old,new):
 p=target/name;s=p.read_text();assert s.count(old)==1,(name,old);p.write_text(s.replace(old,new,1))
replace('common/cpp/include/flutter_webrtc_base.h','bool zero_playout_delay = false);','bool zero_playout_delay = false, bool external_audio_input_only = false);')
replace('common/cpp/include/flutter_webrtc_base.h','bool webrtc_initialized_ = false;','bool webrtc_initialized_ = false;\n  bool external_audio_input_only_ = false;')
replace('common/cpp/src/flutter_webrtc_base.cc','bool zero_playout_delay) {','bool zero_playout_delay, bool external_audio_input_only) {')
replace('common/cpp/src/flutter_webrtc_base.cc','factory_ = LibWebRTC::CreateRTCPeerConnectionFactory();','''libwebrtc::RTCPeerConnectionFactoryOptions factory_options;
  factory_options.external_audio_input_only = external_audio_input_only;
  external_audio_input_only_ = external_audio_input_only;
  factory_ = LibWebRTC::CreateRTCPeerConnectionFactory(factory_options);''')
replace('common/cpp/src/flutter_webrtc.cc','EnsureWebRTCInitialized(findBoolean(options, "enableWARP"),','''const bool external_only = findBoolean(options, "externalAudioInputOnly");
    if (webrtc_initialized_ && external_only != external_audio_input_only_) {
      result->Error("factory_policy_immutable", "Set externalAudioInputOnly before factory initialization");
      return;
    }
    EnsureWebRTCInitialized(findBoolean(options, "enableWARP"),''')
replace('common/cpp/src/flutter_webrtc.cc','findBoolean(options, "zeroPlayoutDelay"));','findBoolean(options, "zeroPlayoutDelay"), external_only);')
replace('lib/src/native/utils.dart','static bool initialized = false;','static bool initialized = false;\n  static bool _externalAudioInputOnly = false;')
replace('lib/src/native/utils.dart',"    if (!initialized) {\n      await _channel.invokeMethod<void>('initialize',","    final requested = options?['externalAudioInputOnly'];\n    if (requested == true && !Platform.isWindows) {\n      throw UnsupportedError('This lab implements external-only factories on Windows');\n    }\n    if (initialized && requested != null && requested != _externalAudioInputOnly) {\n      throw StateError('Set externalAudioInputOnly before factory initialization');\n    }\n    if (!initialized) {\n      await _channel.invokeMethod<void>('initialize',")
replace('lib/src/native/utils.dart','      initialized = true;','      _externalAudioInputOnly = options?["externalAudioInputOnly"] == true;\n      initialized = true;')
replace('common/cpp/src/flutter_webrtc.cc','    GetUserMedia(constraints, std::move(result));','    const auto audio = constraints.find(EncodableValue("audio"));\n    if (external_audio_input_only_ && audio != constraints.end()) {\n      const auto* enabled = std::get_if<bool>(&audio->second);\n      if (!enabled || *enabled) {\n        result->Error("external_audio_only", "Microphone capture is disabled for this factory");\n        return;\n      }\n    }\n    GetUserMedia(constraints, std::move(result));')
# Do not permit automatic downloads or an official-DLL fallback in this lab.
(target/'third_party/CMakeLists.txt').write_text('''get_filename_component(LAB_SDK_ROOT "${CMAKE_CURRENT_LIST_DIR}/libwebrtc" REALPATH)
if(NOT EXISTS "${LAB_SDK_ROOT}/lib/libwebrtc.dll" OR NOT EXISTS "${LAB_SDK_ROOT}/include/libwebrtc.h")
  message(FATAL_ERROR "Stage the matching candidate DLL/import library/headers before building")
endif()
''')
print('Prepared candidate-aware native plugin; stage matching SDK before build')
