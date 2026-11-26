@echo off
rem Builds the app on Windows (run from an interactive scheduled task: plugin
rem symlinks are not readable from the ssh session). Layout under %ROOT%:
rem app\ (the Flutter app), logs\. A short PUB_CACHE of its own: git
rem dependencies (flutter_vrm, flutter_scene) break in the shared cache.
set ROOT=%~dp0..\..
set PUB_CACHE=%USERPROFILE%\work\scpc
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"
cd /d "%ROOT%\app"
call flutter pub get > "%ROOT%\logs\build.log" 2>&1
call flutter build windows --debug >> "%ROOT%\logs\build.log" 2>&1
>>"%ROOT%\logs\build.log" echo build=%ERRORLEVEL%
