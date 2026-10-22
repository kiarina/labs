@echo off
rem Build qwentts.cpp with CUDA on Windows (Visual Studio 2022 Community, CUDA Toolkit 13.4). Run from the lab directory.
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd vendor\qwentts.cpp
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86
cmake --build build --config Release -j %NUMBER_OF_PROCESSORS%
