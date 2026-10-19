@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1 || call "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1 || call "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
cd /d C:\Users\kiarina\pcm_asr
cl /nologo /EHsc /utf-8 /std:c++17 /O2 sapi_probe.cpp /link ole32.lib sapi.lib /out:sapi_probe.exe
echo build=%ERRORLEVEL%
