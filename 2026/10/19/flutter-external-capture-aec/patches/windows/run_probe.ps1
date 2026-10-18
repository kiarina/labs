# Run in an interactive Windows desktop session after building the lab SDK.
param(
    [Parameter(Mandatory=$true)][string]$LabRoot,
    [Parameter(Mandatory=$true)][string]$SdkBuildRoot,
    [ValidateSet('protected','control')][string]$Mode = 'protected',
    [string]$Flutter = 'flutter.bat',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$LabRoot = [System.IO.Path]::GetFullPath($LabRoot)
$SdkBuildRoot = [System.IO.Path]::GetFullPath($SdkBuildRoot)
Set-Location (Join-Path $LabRoot 'app')
if (-not $SkipBuild) {
    & $Flutter build windows --release -t lib/windows_browser_probe.dart
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed' }
}
$release = Join-Path $LabRoot 'app/build/windows/x64/runner/Release'
$builtDll = Join-Path $SdkBuildRoot 'src/out-isolated/libwebrtc.dll'
$loadedDll = Join-Path $release 'libwebrtc.dll'
if (-not (Test-Path $builtDll)) { throw 'Audited SDK missing; run build_sdk.ps1 first' }
Copy-Item -Force $builtDll $loadedDll
$sdkHash = (Get-FileHash -Algorithm SHA256 $loadedDll).Hash.ToLower()
$env:EXTERNAL_SYNTHETIC = 'false'
$env:EXTERNAL_REAL_AUDIO = 'true'
$env:EXTERNAL_EXIT = 'true'
$env:EXTERNAL_CAPTURE_RECORDING_CONTROL = if ($Mode -eq 'control') { '1' } else { '0' }
$env:EXTERNAL_RESULT_NAME = 'external_browser_result_' + [guid]::NewGuid().ToString('N') + '.json'
$resultFile = Join-Path $env:TEMP $env:EXTERNAL_RESULT_NAME
$process = Start-Process -FilePath (Join-Path $release 'external_capture_app.exe') -WorkingDirectory $release -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Probe process failed: $($process.ExitCode)" }
if (-not (Test-Path $resultFile)) { throw 'Probe produced no result' }
$result = Get-Content $resultFile -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force (Join-Path $LabRoot 'results') | Out-Null
$destination = Join-Path $LabRoot "results/windows-recording-$Mode.json"
Copy-Item -Force $resultFile $destination
Remove-Item $resultFile
if ($result.sdkSha256 -ne $sdkHash) { throw 'Loaded SDK fingerprint differs from the copied audited SDK' }
if (-not $result.recordingAudit) { throw 'Probe did not report recording audit counters' }
if (-not $result.pass) { throw "Media probe failed; inspect $destination" }
Write-Output "Completed $Mode with SDK SHA256 $sdkHash"
Write-Output ($result.recordingAudit | ConvertTo-Json -Compress)
