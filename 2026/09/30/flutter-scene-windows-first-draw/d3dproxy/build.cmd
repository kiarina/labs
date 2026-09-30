@echo off
rem Builds d3dcompiler_47.dll (the stand-in) with the MSVC x64 tools.
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
cl /nologo /O2 /EHsc /LD /std:c++17 d3dproxy.cpp /link /DEF:d3dproxy.def /OUT:d3dcompiler_47.dll
