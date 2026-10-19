param(
 [Parameter(Mandatory=$true)][string]$LabRoot,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$Speaker='EDIFIER',
 [string]$Variant='external',
 [bool]$ExternalOnly=$true,
 [switch]$Pilot,
 [string]$LoopbackProbe,
 [double]$RequestedReceiverVolume=0
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($LabRoot)
$sdk=Get-Content "$root/build-sdk-manifest.json"|ConvertFrom-Json
$exe="$root/app/build/windows/x64/runner/Release/upstream_input_app.exe"
if((Get-FileHash (Join-Path (Split-Path $exe) 'libwebrtc.dll')).Hash.ToLower() -ne $sdk.dllSha256){throw 'DLL mismatch'}
$env:UPSTREAM_MEASURE_STOPS='1';$env:UPSTREAM_SELECT_PLAYOUT='0'
$env:UPSTREAM_PUBLIC_OUTPUT=$Speaker;$env:UPSTREAM_PILOT_TONE=if($Pilot){'1'}else{'0'}
$env:UPSTREAM_DISABLE_NATIVE_PLAYOUT='0';$env:UPSTREAM_VARIANT=$Variant
$env:UPSTREAM_MIC='DualSense';$env:UPSTREAM_CAMERA_MODE='synthetic'
$env:UPSTREAM_EXTERNAL_ONLY=if($ExternalOnly){'1'}else{'0'}
$env:UPSTREAM_EXPECTED_SHA256=$sdk.dllSha256;$env:UPSTREAM_EXIT='true'
$env:UPSTREAM_RECEIVER_VOLUME=$RequestedReceiverVolume.ToString([Globalization.CultureInfo]::InvariantCulture)
$observer=$null
if($Pilot){
 if(!(Test-Path $LoopbackProbe)){throw 'Pilot requires a render-loopback observer'}
 if(Test-Path "$root/playout-loopback.jsonl"){throw 'Preserve existing loopback metrics; use a fresh copy'}
 $observer=Start-Process -FilePath $LoopbackProbe -ArgumentList '45' -PassThru -RedirectStandardOutput "$root/playout-loopback.jsonl" -RedirectStandardError "$root/playout-loopback-error.log"
 $null=$observer.Handle
 Start-Sleep -Seconds 1
}
& "$root/tools/windows/collect.ps1" -Executable $exe -OutputDirectory $OutputDirectory
$sdk|ConvertTo-Json|Set-Content -Encoding ASCII (Join-Path $OutputDirectory 'sdk-manifest.json')
@{externalOnly=$ExternalOnly;variant=$Variant;nativePlayoutDiagnostic=$false;pilotTone=[bool]$Pilot;requestedReceiverVolume=$RequestedReceiverVolume}|ConvertTo-Json|Set-Content (Join-Path $OutputDirectory 'trial-policy.json')
if($observer){$observer.WaitForExit();if($observer.ExitCode -ne 0){throw 'Loopback observer failed'}}
