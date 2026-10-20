# Run the release app once on the interactive desktop (ssh lands in session 0).
# Usage: powershell -File launch.ps1 -Session win-fake-1 -Env "LAB_PEER=http://...;LAB_EXIT=1"
param(
 [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Session,
 [string]$Env='',
 [int]$TimeoutSeconds=420
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$exe=Join-Path $root 'app\build\windows\x64\runner\Release\gpt_live_playout_lab.exe'
$out=Join-Path $root "build\trials"
New-Item -ItemType Directory -Force $out | Out-Null
$done=Join-Path $out "$Session.done"
Remove-Item $done -ErrorAction SilentlyContinue
$lines=@('@echo off',"set LAB_SESSION=$Session","set LAB_OUT_DIR=$out",'set AEC_RECORD_RAW=1')
foreach($kv in ($Env -split ';')){ if($kv){ $lines+="set $kv" } }
$lines+="`"$exe`" > `"$out\$Session.log`" 2>&1"
$lines+="echo exit=%errorlevel% > `"$done`""
$cmd=Join-Path $out "$Session.cmd"
Set-Content -Encoding ASCII $cmd $lines
schtasks /create /tn GptLivePlayoutLab /tr $cmd /sc once /st 23:59 /it /f | Out-Null
schtasks /run /tn GptLivePlayoutLab | Out-Null
$t=0
while(!(Test-Path $done) -and $t -lt $TimeoutSeconds){ Start-Sleep 2; $t+=2 }
schtasks /delete /tn GptLivePlayoutLab /f | Out-Null
if(!(Test-Path $done)){ taskkill /im gpt_live_playout_lab.exe /f 2>$null | Out-Null; "timeout" }
else { Get-Content $done }
