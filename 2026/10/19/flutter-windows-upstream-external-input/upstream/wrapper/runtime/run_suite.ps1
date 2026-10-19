param(
 [Parameter(Mandatory=$true)][string]$LabRoot,
 [Parameter(Mandatory=$true)][string]$LegacyRelease
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($LabRoot)
$env:UPSTREAM_MEASURE_STOPS='1'
New-Item -ItemType Directory -Force "$root/build/trials" | Out-Null
$trials=@(
 @{label='record-only';variant='record-only';externalOnly=$true;diagnostic=$false},
 @{label='native-mic-default';variant='native-mic';externalOnly=$false;diagnostic=$false},
 @{label='external-default';variant='external';externalOnly=$false;diagnostic=$false},
 @{label='external-only';variant='external';externalOnly=$true;diagnostic=$false},
 @{label='external-muted';variant='muted';externalOnly=$true;diagnostic=$false},
 @{label='external-native-playout-off';variant='external';externalOnly=$true;diagnostic=$true},
 @{label='external-track-gates-playout-off';variant='track-gates';externalOnly=$true;diagnostic=$true},
 @{label='external-replace-gates-playout-off';variant='replace-gates';externalOnly=$true;diagnostic=$true}
)
try {
 foreach($trial in $trials){
  @{state='running';trial=$trial.label;utc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content "$root/suite-status.json"
  & "$root/tools/windows/run_trial.ps1" -Variant $trial.variant -ExternalOnly $trial.externalOnly -NativePlayoutDiagnostic $trial.diagnostic -OutputDirectory "$root/build/trials/$($trial.label)" -SdkManifest "$root/build-sdk-manifest.json" *> "$root/run-$($trial.label).log"
 }
 @{state='trials-complete';utc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content "$root/suite-status.json"
 & "$PSScriptRoot/run_abi.ps1" -LabRoot $root -LegacyRelease $LegacyRelease *> "$root/run-abi.log"
 @{state='complete';utc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content "$root/suite-status.json"
} catch {
 @{state='failed';error=$_.Exception.Message;utc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content "$root/suite-status.json"
 throw
}
