# Run the release app once on the interactive desktop (ssh lands in session 0).
# Usage: powershell -File launch.ps1 -Session win-fake-1 -Env "LAB_PEER=http://...;LAB_EXIT=1"
param(
 [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Session,
 [string]$Env='',
 [int]$TimeoutSeconds=420,
 [switch]$Vc,
 [int]$VcPort=18810
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$exe=Join-Path $root 'app\build\windows\x64\runner\Release\remote_audio_tap_lab.exe'
$out=Join-Path $root "build\trials"
New-Item -ItemType Directory -Force $out | Out-Null
$done=Join-Path $out "$Session.done"
Remove-Item $done -ErrorAction SilentlyContinue
$vcProcess=$null
if($Vc){
 $vcLog=Join-Path $out "$Session-vc.log"
 Remove-Item $vcLog -ErrorAction SilentlyContinue
 $vcProcess=Start-Process -PassThru -WindowStyle Hidden -FilePath uv -WorkingDirectory (Join-Path $root 'vc') -ArgumentList @('run','python','server.py','--port',"$VcPort",'--stats',(Join-Path $out "$Session-vc-sessions.jsonl")) -RedirectStandardOutput $vcLog -RedirectStandardError "$vcLog.err"
 $w=0
 while(!((Test-Path $vcLog) -and (Select-String -Quiet -Path $vcLog -Pattern '"ready"')) -and $w -lt 120){ Start-Sleep 1; $w++ }
 if($w -ge 120){ Stop-Process -Id $vcProcess.Id -Force; throw 'VC server did not become ready' }
}
$lines=@('@echo off',"set LAB_SESSION=$Session","set LAB_OUT_DIR=$out",'set AEC_RECORD_RAW=1')
foreach($kv in ($Env -split ';')){ if($kv){ $lines+="set $kv" } }
$lines+="`"$exe`" > `"$out\$Session.log`" 2>&1"
$lines+="echo exit=%errorlevel% > `"$done`""
$cmd=Join-Path $out "$Session.cmd"
Set-Content -Encoding ASCII $cmd $lines
schtasks /create /tn RemoteAudioTapLab /tr $cmd /sc once /st 23:59 /it /f | Out-Null
schtasks /run /tn RemoteAudioTapLab | Out-Null
$t=0
while(!(Test-Path $done) -and $t -lt $TimeoutSeconds){ Start-Sleep 2; $t+=2 }
schtasks /delete /tn RemoteAudioTapLab /f | Out-Null
if($vcProcess){ Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*server.py --port*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Stop-Process -Id $vcProcess.Id -Force -ErrorAction SilentlyContinue }
if(!(Test-Path $done)){ taskkill /im remote_audio_tap_lab.exe /f 2>$null | Out-Null; "timeout" }
else { Get-Content $done }
