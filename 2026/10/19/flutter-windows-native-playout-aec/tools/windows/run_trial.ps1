param(
 [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Session,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$SdkManifest,
 [string]$Executable,
 [string]$Peer='http://127.0.0.1:18794',
 [string]$MicrophoneId='',
 [ValidateSet('baseline','conditioned')][string]$Output='baseline',
 [double]$NearGain=0.05,
 [switch]$Human,
 [switch]$PositiveControl
)
# Elevated interactive desktop, one fresh process/trial. Never change OS volumes.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$sdk=Get-Content $SdkManifest|ConvertFrom-Json
if(!$Executable){$Executable=Join-Path $root 'app/build/windows/x64/runner/Release/upstream_input_app.exe'}
$release=Split-Path ([IO.Path]::GetFullPath($Executable))
if((Get-FileHash (Join-Path $release 'libwebrtc.dll')).Hash.ToLower() -ne $sdk.dllSha256){throw 'Candidate DLL identity mismatch'}
$env:AEC_SESSION=$Session
$env:AEC_HUMAN=if($Human){'1'}else{'0'}
$env:AEC_CONTROL=if($PositiveControl){'1'}else{'0'}
$env:AEC_EXTERNAL_ONLY=if($PositiveControl){'0'}else{'1'}
$env:AEC_OUTPUT=$Output
$env:AEC_NEAR_GAIN=$NearGain.ToString([Globalization.CultureInfo]::InvariantCulture)
$env:AEC_PEER=$Peer
$env:AEC_RECORD_RAW='1'
$env:AEC_AUTO_START=if($Human){'0'}else{'1'}
$env:AEC_EXIT='1'
if($MicrophoneId){$env:AEC_MIC_ID=$MicrophoneId}else{Remove-Item Env:AEC_MIC_ID -ErrorAction SilentlyContinue}
$env:UPSTREAM_VARIANT='normal-native-aec'
$env:UPSTREAM_AUDIO_PROCESSING_OFF='1'
$env:UPSTREAM_EXPECTED_SHA256=$sdk.dllSha256
& "$PSScriptRoot/collect.ps1" -Executable $Executable -OutputDirectory $OutputDirectory
$latest=Get-Content -Encoding UTF8 (Join-Path $env:TEMP 'native_aec_latest.json')|ConvertFrom-Json
if($latest.session -ne $Session){throw 'No current session result'}
Copy-Item -Recurse $latest.folder (Join-Path $OutputDirectory 'artifacts')
$sdk|ConvertTo-Json|Set-Content -Encoding ASCII (Join-Path $OutputDirectory 'sdk-manifest.json')
@{session=$Session;human=[bool]$Human;control=[bool]$PositiveControl;externalOnly=![bool]$PositiveControl;output=$Output;nearGain=$NearGain}|ConvertTo-Json|Set-Content -Encoding ASCII (Join-Path $OutputDirectory 'trial-policy.json')
if($latest.errors.Count){throw 'Trial completed with application errors; preserve artifacts'}
