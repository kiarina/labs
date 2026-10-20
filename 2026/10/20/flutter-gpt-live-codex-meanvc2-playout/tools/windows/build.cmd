@echo off
rem Release build with an isolated short-path pub cache (the shared cache produced an incomplete package graph; a deep path hit Filename too long).
cd /d "%~dp0..\..\app"
if "%LAB_PUB_CACHE%"=="" set LAB_PUB_CACHE=%USERPROFILE%\work\gpc
set PUB_CACHE=%LAB_PUB_CACHE%
if exist .dart_tool rmdir /s /q .dart_tool
call flutter pub get > ..\build\pubget.log 2>&1 || exit /b 1
call flutter build windows --release > ..\build\windows-build.log 2>&1
echo build=%errorlevel% >> ..\build\windows-build.log
