@echo off
rem Starts the app on the desktop (from an interactive scheduled task), with
rem the lab's settings as environment variables. Layout under %ROOT%: media\,
rem scenes\, saved\, logs\, Seed-san.vrm, test.vrma, app\.
set ROOT=%~dp0..\..
set MEDIA_DIR=%ROOT%\media
set SCENES_DIR=%ROOT%\scenes
set SAVED_SCENES_DIR=%ROOT%\saved
set VRM_PATH=%ROOT%\Seed-san.vrm
set VRMA_PATH=%ROOT%\test.vrma
set LOG_DIR=%ROOT%\logs
set CONTROL_PORT=8816
set MODEL=gpt-6.2-sol
start "" "%ROOT%\app\build\windows\x64\runner\Debug\spirit_canvas.exe"
>>"%ROOT%\logs\run.log" echo run=%ERRORLEVEL%
