param(
 [Parameter(Mandatory=$true)][string]$Executable,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$Xperf='xperf.exe'
)
$ErrorActionPreference='Stop'
# Run in an elevated interactive desktop. Never cancel another WPR session.
if(!(Test-Path $Executable)){throw 'Executable does not exist'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path $OutputDirectory){throw 'Use a fresh output directory for each process'}
New-Item -ItemType Directory $OutputDirectory|Out-Null
& "$PSScriptRoot/endpoint_volume.ps1" | Set-Content -Encoding UTF8 "$OutputDirectory/volume-before.txt"
$profile=Join-Path $PSScriptRoot 'audio-client.wprp'
$trace=Join-Path $OutputDirectory 'trace.etl'
& wpr -start "$profile!LabAudio" -filemode *> "$OutputDirectory/collector-start.log"
if($LASTEXITCODE -ne 0){throw 'WPR start failed; existing trace was not cancelled'}
try {
 $startedAt=Get-Date
 $proc=Start-Process -FilePath ([IO.Path]::GetFullPath($Executable)) -WorkingDirectory (Split-Path ([IO.Path]::GetFullPath($Executable))) -PassThru -RedirectStandardOutput "$OutputDirectory/process.log" -RedirectStandardError "$OutputDirectory/process-error.log"
 $targetPid=$proc.Id
 $proc.WaitForExit()
 @{pid=$targetPid;executable=[IO.Path]::GetFileName($Executable);exitCode=$proc.ExitCode;variant=$env:UPSTREAM_VARIANT}|ConvertTo-Json|Set-Content -Encoding UTF8 "$OutputDirectory/process.json"
 foreach($name in 'upstream_input_result.json','upstream_input_stages.jsonl') {
  $path=Join-Path $env:TEMP $name
  if((Test-Path $path) -and (Get-Item $path).LastWriteTime -ge $startedAt) {
   Copy-Item $path (Join-Path $OutputDirectory $name)
  }
 }
} finally {
 & wpr -stop $trace *> "$OutputDirectory/collector-stop.log"
 if($LASTEXITCODE -ne 0){throw 'WPR stop failed; inspect collector-stop.log'}
}
& "$PSScriptRoot/endpoint_volume.ps1" | Set-Content -Encoding UTF8 "$OutputDirectory/volume-after.txt"
$statsProc=Start-Process -FilePath $Xperf -ArgumentList @('-i',('"'+$trace+'"'),'-a','tracestats') -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$OutputDirectory/trace-stats.txt" -RedirectStandardError "$OutputDirectory/stats-error.log"
if($statsProc.ExitCode -ne 0){throw 'Trace statistics failed'}
$dumpProc=Start-Process -FilePath $Xperf -ArgumentList @('-i',('"'+$trace+'"'),'-o',('"'+$OutputDirectory+'/events.csv"'),'-a','dumper') -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$OutputDirectory/dump.log" -RedirectStandardError "$OutputDirectory/dump-error.log"
if($dumpProc.ExitCode -ne 0){throw 'Trace dump failed'}
& "$PSScriptRoot/build/etl-stacks.exe" $trace $targetPid 2> "$OutputDirectory/parser.log" | Set-Content -Encoding UTF8 "$OutputDirectory/stacks.jsonl"
if($LASTEXITCODE -ne 0){throw 'ETL stack parsing failed'}
# Raw ETL/CSV contains local process/path metadata. Keep it private.
python "$PSScriptRoot/normalize_trace.py" "$OutputDirectory/events.csv" "$OutputDirectory/stacks.jsonl" $targetPid "$OutputDirectory/normalized.json"
if($LASTEXITCODE -ne 0){throw 'Trace normalization failed'}
