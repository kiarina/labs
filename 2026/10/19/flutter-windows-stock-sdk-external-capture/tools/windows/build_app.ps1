param([Parameter(Mandatory=$true)][string]$LabRoot,[string]$Flutter='flutter.bat')
$ErrorActionPreference='Stop'
Push-Location (Join-Path $LabRoot 'app')
try {
 & $Flutter pub get
 if($LASTEXITCODE -ne 0){throw 'flutter pub get failed'}
 & $Flutter build windows --release
 if($LASTEXITCODE -ne 0){throw 'Windows release build failed'}
} finally { Pop-Location }
