@echo off
setlocal
rem Run from a VS2022 x64 Native Tools prompt, or pass vcvars64.bat as argument.
if not "%~1"=="" call "%~1"
if errorlevel 1 exit /b 1
pushd "%~dp0"
if not exist build mkdir build
cl /nologo /O2 /EHsc /std:c++17 mic_control.cc ole32.lib /Fe:build\mic-control.exe /Fo:build\mic-control.obj
if errorlevel 1 exit /b 1
cl /nologo /O2 /EHsc /std:c++17 etl_stacks.cc tdh.lib advapi32.lib ole32.lib /Fe:build\etl-stacks.exe /Fo:build\etl-stacks.obj
set OBSERVER_BUILD_RESULT=%ERRORLEVEL%
popd
exit /b %OBSERVER_BUILD_RESULT%
