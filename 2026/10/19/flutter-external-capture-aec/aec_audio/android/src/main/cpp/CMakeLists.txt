cmake_minimum_required(VERSION 3.22)
project(aec_audio_android LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../../../../native" "${CMAKE_CURRENT_BINARY_DIR}/aec_engine")
add_library(aec_audio_android SHARED aec_audio_jni.cc)
target_link_libraries(aec_audio_android PRIVATE aec_engine log)
# This extraction ships Android and Linux CPU probes defining the same symbol.
# Android uses the NDK cpufeatures implementation, including on ARM64.
get_target_property(AEC_SOURCES aec_engine SOURCES)
list(FILTER AEC_SOURCES EXCLUDE REGEX ".*/cpu_features_linux\\.c$")
set_property(TARGET aec_engine PROPERTY SOURCES "${AEC_SOURCES}")
target_sources(aec_engine PRIVATE "${ANDROID_NDK}/sources/android/cpufeatures/cpu-features.c")
target_include_directories(aec_engine PRIVATE "${ANDROID_NDK}/sources/android/cpufeatures")
# Keep extraction C helpers private too; namespace rewriting covers C++ only.
target_compile_options(aec_engine PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden)
target_link_options(aec_engine PRIVATE "-Wl,--exclude-libs,ALL")
