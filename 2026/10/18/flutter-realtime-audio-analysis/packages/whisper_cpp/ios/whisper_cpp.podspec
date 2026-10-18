#
# whisper.cpp + ggml for Flutter (dart:ffi).
#
# whisper.cpp itself is built by its own CMake (tool/build_apple.sh) in a
# script phase that runs before compilation, for the current platform
# (macosx / iphoneos / iphonesimulator) and $(ARCHS): Metal with the shaders
# embedded (GGML_METAL_EMBED_LIBRARY), BLAS via Accelerate, no OpenMP.
# The resulting static archive is linked into this pod's framework together
# with the C shim in Classes/ (a forwarder to ../src/whisper_cpp.c, because
# podspecs cannot reference files outside their directory).
#
# Prerequisites: packages/whisper_cpp/tool/fetch_whisper_cpp.sh, cmake on PATH
# (Homebrew is searched).
#
Pod::Spec.new do |s|
  s.name             = 'whisper_cpp'
  s.version          = '0.1.0'
  s.summary          = 'whisper.cpp (local Whisper ASR) for Flutter via dart:ffi.'
  s.description      = 'whisper.cpp with Metal and Accelerate, loaded once and driven from a Dart isolate.'
  s.homepage         = 'https://github.com/ggml-org/whisper.cpp'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'labs' => 'labs@example.invalid' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.6'

  s.script_phase = {
    :name => 'Build whisper.cpp (CMake)',
    # The copy next to the pod's product lets an app that links pods
    # statically (use_frameworks! :linkage => :static, which
    # flutter_onnxruntime requires) link the archive itself; see
    # user_target_xcconfig.
    :script => '"${PODS_TARGET_SRCROOT}/../tool/build_apple.sh" "${TARGET_TEMP_DIR}/whisper_cmake" && mkdir -p "${CONFIGURATION_BUILD_DIR}" && cp -p "${TARGET_TEMP_DIR}/whisper_cmake/lib/libwhisper_all.a" "${CONFIGURATION_BUILD_DIR}/libwhisper_all.a"',
    :execution_position => :before_compile,
    :always_out_of_date => '1',
  }

  s.frameworks = 'Accelerate', 'Metal', 'MetalKit', 'Foundation'
  s.libraries = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../src" "$(PODS_TARGET_SRCROOT)/../third_party/whisper.cpp/include" "$(PODS_TARGET_SRCROOT)/../third_party/whisper.cpp/ggml/include"',
    # Same backend macros ggml's CMake exports (used by wcpp_backend()).
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GGML_USE_METAL=1 GGML_USE_BLAS=1 GGML_USE_CPU=1',
    'OTHER_LDFLAGS' => '-L"$(TARGET_TEMP_DIR)/whisper_cmake/lib" -lwhisper_all',
    # The script phase writes outside the sandboxed locations.
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
  }
  # With static pod linkage nothing references the dart:ffi entry points, so
  # the linker would leave the shim (and whisper.cpp) out of the app. -u keeps
  # them; -lwhisper_all then resolves whisper.cpp from the archive. With
  # dynamic frameworks the symbols come from the framework and the archive is
  # not pulled.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -L"$(PODS_CONFIGURATION_BUILD_DIR)/whisper_cpp" -lwhisper_all -Wl,-u,_wcpp_backend -Wl,-u,_wcpp_free -Wl,-u,_wcpp_init_from_buffer -Wl,-u,_wcpp_init_from_file -Wl,-u,_wcpp_n_segments -Wl,-u,_wcpp_result_language -Wl,-u,_wcpp_segment_t0 -Wl,-u,_wcpp_segment_t1 -Wl,-u,_wcpp_segment_text -Wl,-u,_wcpp_set_log_enabled -Wl,-u,_wcpp_system_info -Wl,-u,_wcpp_transcribe',
  }
  s.swift_version = '5.0'
end
