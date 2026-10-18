# Builds whisper.cpp + ggml as static libraries and links them into one
# shared library `whisper_cpp` together with the C shim (whisper_cpp.c).
#
# Used directly by Android (android/build.gradle) and Windows
# (windows/CMakeLists.txt). macOS / iOS use tool/build_apple.sh, which builds
# only the static libraries from here (WCPP_APPLE_STATIC_ONLY=ON) and lets
# CocoaPods compile the shim into the plugin framework.
#
# ggml requires CMake 3.14.
cmake_minimum_required(VERSION 3.14)

project(whisper_cpp_library VERSION 0.1.0 LANGUAGES C CXX)

set(WCPP_WHISPER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/whisper.cpp"
    CACHE PATH "whisper.cpp source tree")
if (NOT EXISTS "${WCPP_WHISPER_DIR}/include/whisper.h")
  message(FATAL_ERROR
    "whisper.cpp sources not found at ${WCPP_WHISPER_DIR}. "
    "Run packages/whisper_cpp/tool/fetch_whisper_cpp.sh first.")
endif()

option(WCPP_APPLE_STATIC_ONLY "Only build the static whisper/ggml libraries" OFF)

# Static libraries linked into one shared object -> PIC everywhere.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL           OFF CACHE BOOL "" FORCE)
set(WHISPER_SDL2           OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS   OFF CACHE BOOL "" FORCE)
# The release tarball still defaults to a "-dev" version suffix.
set(WHISPER_BUILD_IS_DEV   OFF CACHE BOOL "" FORCE)

# Portable binaries: never -march=native. OpenMP off everywhere (ggml's own
# thread pool; avoids shipping libomp / vcomp).
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)

if (ANDROID)
  # CPU only. Baseline armv8-a (NEON is mandatory on arm64) so that every
  # arm64 device can load it. Set e.g. -DWCPP_ANDROID_ARM_ARCH=armv8.2-a+dotprod+fp16
  # to trade compatibility for speed.
  set(WCPP_ANDROID_ARM_ARCH "" CACHE STRING "GGML_CPU_ARM_ARCH for arm64-v8a")
  set(GGML_METAL  OFF CACHE BOOL "" FORCE)
  set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
  set(GGML_BLAS   OFF CACHE BOOL "" FORCE)
  set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
  if (ANDROID_ABI STREQUAL "arm64-v8a" AND WCPP_ANDROID_ARM_ARCH)
    set(GGML_CPU_ARM_ARCH "${WCPP_ANDROID_ARM_ARCH}" CACHE STRING "" FORCE)
  endif()
  if (ANDROID_ABI STREQUAL "x86_64")
    # Emulator / ChromeOS: stay at SSE4.2-level x86-64 (no AVX), the
    # emulator does not always expose AVX2.
    set(GGML_AVX  OFF CACHE BOOL "" FORCE)
    set(GGML_AVX2 OFF CACHE BOOL "" FORCE)
    set(GGML_FMA  OFF CACHE BOOL "" FORCE)
    set(GGML_F16C OFF CACHE BOOL "" FORCE)
    set(GGML_BMI2 OFF CACHE BOOL "" FORCE)
  endif()
  # AGP builds release variants as RelWithDebInfo (-O2) and debug as -O0;
  # whisper is unusable at -O0, so force -O3 for every variant.
  add_compile_options(-O3)
elseif (WIN32 AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|x86_64|x64)$")
  # x64 CPU with AVX2 (Haswell+ / Zen+). Vulkan (GGML_VULKAN) would be the
  # GPU option on Windows but needs the Vulkan SDK at build time; not enabled.
  set(GGML_AVX  ON CACHE BOOL "" FORCE)
  set(GGML_AVX2 ON CACHE BOOL "" FORCE)
  set(GGML_FMA  ON CACHE BOOL "" FORCE)
  set(GGML_F16C ON CACHE BOOL "" FORCE)
  set(GGML_BMI2 ON CACHE BOOL "" FORCE)
  set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
  set(GGML_CUDA   OFF CACHE BOOL "" FORCE)
  # The DLL must not depend on anything besides the MSVC runtime that
  # Flutter apps already ship.
  set(GGML_BLAS   OFF CACHE BOOL "" FORCE)
elseif (APPLE)
  set(GGML_METAL ON CACHE BOOL "" FORCE)
  set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
  set(GGML_METAL_USE_BF16 ON CACHE BOOL "" FORCE)
  set(GGML_BLAS ON CACHE BOOL "" FORCE)
  set(GGML_BLAS_VENDOR Apple CACHE STRING "" FORCE)
  set(GGML_ACCELERATE ON CACHE BOOL "" FORCE)
endif()

add_subdirectory("${WCPP_WHISPER_DIR}" whisper.cpp EXCLUDE_FROM_ALL)

if (WCPP_APPLE_STATIC_ONLY)
  add_custom_target(wcpp_static_deps ALL DEPENDS whisper)
  return()
endif()

add_library(whisper_cpp SHARED "whisper_cpp.c")
target_link_libraries(whisper_cpp PRIVATE whisper)
set_target_properties(whisper_cpp PROPERTIES OUTPUT_NAME "whisper_cpp")
target_compile_definitions(whisper_cpp PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16 KB page size.
  target_link_options(whisper_cpp PRIVATE "-Wl,-z,max-page-size=16384")
  # Keep only the wcpp_* exports; drop the static libs' symbols.
  target_link_options(whisper_cpp PRIVATE "-Wl,--exclude-libs,ALL" "-Wl,--gc-sections")
  find_library(WCPP_LOG_LIB log)
  target_link_libraries(whisper_cpp PRIVATE ${WCPP_LOG_LIB})
endif()
