param(
 [Parameter(Mandatory=$true)][string]$LabRoot,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$Variant,
 [ValidateSet('03','05')][string]$SdkVersion='03',
 [string]$Microphone='DualSense',[string]$Speaker='EDIFIER',
 [double]$ReceiverVolume=0,[switch]$SelectPlayout,[switch]$ProcessingOff
)
$ErrorActionPreference='Stop'
$manifest=Get-Content "$PSScriptRoot/../../results/official-sdks.json"|ConvertFrom-Json
$sdk=$manifest.sdks|Where-Object{$_.tag -eq "libwebrtc.m150.7871.$SdkVersion"}
$release=Join-Path $LabRoot 'app/build/windows/x64/runner/Release'
if((Get-FileHash (Join-Path $release 'libwebrtc.dll')).Hash.ToLower() -ne $sdk.dllSha256){throw 'Deployed official SDK identity mismatch'}
$env:STOCK_VARIANT=$Variant
$env:STOCK_MIC=$Microphone
$env:STOCK_SPEAKER=$Speaker
$env:STOCK_CAMERA_MODE='synthetic'
$env:STOCK_EXPECTED_SHA256=$sdk.dllSha256
$env:STOCK_EXIT='true'
$env:STOCK_SELECT_PLAYOUT=if($SelectPlayout){'1'}else{'0'}
$env:STOCK_AUDIO_PROCESSING_OFF=if($ProcessingOff){'1'}else{'0'}
$env:STOCK_RECEIVER_VOLUME=[string]$ReceiverVolume
& "$PSScriptRoot/collect.ps1" -Executable (Join-Path $release 'stock_capture_app.exe') -OutputDirectory $OutputDirectory
