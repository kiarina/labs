param(
 [Parameter(Mandatory=$true)][string]$Variant,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$SdkManifest,
 [bool]$ExternalOnly=$true,
 [bool]$NativePlayoutDiagnostic=$false,
 [string]$Microphone='DualSense'
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$sdk=Get-Content $SdkManifest|ConvertFrom-Json
$release=Join-Path $root 'app/build/windows/x64/runner/Release'
if((Get-FileHash (Join-Path $release 'libwebrtc.dll')).Hash.ToLower() -ne $sdk.dllSha256){throw 'Candidate DLL identity mismatch'}
$env:UPSTREAM_DISABLE_NATIVE_PLAYOUT=if($NativePlayoutDiagnostic){'1'}else{'0'}
$env:UPSTREAM_VARIANT=$Variant
$env:UPSTREAM_MIC=$Microphone
$env:UPSTREAM_CAMERA_MODE='synthetic'
$env:UPSTREAM_EXTERNAL_ONLY=if($ExternalOnly){'1'}else{'0'}
$env:UPSTREAM_EXPECTED_SHA256=$sdk.dllSha256
$env:UPSTREAM_EXIT='true'
$env:UPSTREAM_RECEIVER_VOLUME='0'
& "$PSScriptRoot/collect.ps1" -Executable (Join-Path $release 'upstream_input_app.exe') -OutputDirectory $OutputDirectory
$sdk|ConvertTo-Json|Set-Content -Encoding ASCII (Join-Path $OutputDirectory 'sdk-manifest.json')
@{externalOnly=$ExternalOnly;variant=$Variant;nativePlayoutDiagnostic=$NativePlayoutDiagnostic}|ConvertTo-Json|Set-Content -Encoding ASCII (Join-Path $OutputDirectory 'trial-policy.json')
