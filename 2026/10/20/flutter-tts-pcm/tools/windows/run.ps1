# Builds the lab app on Windows and runs it once in the interactive desktop
# session (GUI apps started from SSH's session 0 die). Copy the lab first
# (without build directories), then:
#   powershell -ExecutionPolicy Bypass -File tools\windows\run.ps1 [-ModelDir <whisper model folder>] [-NoAsr]
param(
  [string]$ModelDir = '',
  [switch]$NoAsr,
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$lab = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$app = Join-Path $lab 'app'
$log = Join-Path $lab 'build\windows.log'
New-Item -ItemType Directory -Force -Path (Join-Path $lab 'build') | Out-Null

if (-not $SkipBuild) {
  $vk = Get-ChildItem C:\VulkanSDK -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if ($vk) { $env:VULKAN_SDK = $vk.FullName; $env:PATH = "$($vk.FullName)\Bin;$env:PATH" }
  Push-Location $app
  cmd /c "flutter pub get > ..\build\pub.log 2>&1"
  cmd /c "flutter build windows --release > ..\build\build-windows.log 2>&1"
  $code = $LASTEXITCODE
  Pop-Location
  if ($code -ne 0) { Get-Content (Join-Path $lab 'build\build-windows.log') -Tail 40; throw "build failed ($code)" }
}

$exe = Join-Path $app 'build\windows\x64\runner\Release\tts_app.exe'
$result = Join-Path $env:TEMP 'tts_result.json'
Remove-Item $result -ErrorAction SilentlyContinue
$config = if ($NoAsr) { '{"exit":true,"asr":false}' } else { '{"exit":true}' }
$cmd = Join-Path $lab 'build\run-tts.cmd'
@"
@echo off
set TTS_CONFIG=$config
set TTS_ASR_MODEL_DIR=$ModelDir
"$exe"
"@ | Set-Content -Encoding ascii $cmd

schtasks /create /tn tts_pcm_lab /tr $cmd /sc once /st 23:59 /it /f | Out-Null
schtasks /run /tn tts_pcm_lab | Out-Null
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline -and -not (Test-Path $result)) { Start-Sleep 3 }
Start-Sleep 2
schtasks /delete /tn tts_pcm_lab /f | Out-Null
if (-not (Test-Path $result)) { taskkill /im tts_app.exe /f 2>$null; throw 'no result' }
Copy-Item $result (Join-Path $lab 'build\windows-result.json') -Force
Write-Host "result=$(Join-Path $lab 'build\windows-result.json')"
