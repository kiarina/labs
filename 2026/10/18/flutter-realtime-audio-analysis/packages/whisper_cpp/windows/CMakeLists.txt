# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "whisper_cpp")
project(${PROJECT_NAME} LANGUAGES C CXX)

# whisper.cpp + ggml (static, x64 AVX2, CPU only) and the C shim, built into
# whisper_cpp.dll by ../src/CMakeLists.txt. Run ../tool/fetch_whisper_cpp.sh
# (Git Bash) before the first build.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# Note: `flutter run` (Debug) builds this unoptimized (/Od /RTC1) and whisper
# is then far too slow; measure with --profile or --release.

set(whisper_cpp_bundled_libraries
  $<TARGET_FILE:whisper_cpp>
  PARENT_SCOPE
)
