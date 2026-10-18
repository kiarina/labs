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
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '14.0'

  s.script_phase = {
    :name => 'Build whisper.cpp (CMake)',
    :script => '"${PODS_TARGET_SRCROOT}/../tool/build_apple.sh" "${TARGET_TEMP_DIR}/whisper_cmake"',
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
  s.swift_version = '5.0'
end
