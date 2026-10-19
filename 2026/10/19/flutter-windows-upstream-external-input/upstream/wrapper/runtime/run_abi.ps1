param(
 [Parameter(Mandatory=$true)][string]$LabRoot,
 [Parameter(Mandatory=$true)][string]$LegacyRelease
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($LabRoot)
$target=Join-Path $root 'build/abi-release'
if(Test-Path $target){throw 'Fresh ABI copy required'}
Copy-Item -Recurse $LegacyRelease $target
$sdk=Get-Content "$root/build-sdk-manifest.json"|ConvertFrom-Json
Copy-Item "$root/vendor/flutter_webrtc/third_party/libwebrtc/lib/libwebrtc.dll" "$target/libwebrtc.dll" -Force
if((Get-FileHash "$target/libwebrtc.dll").Hash.ToLower() -ne $sdk.dllSha256){throw 'Candidate identity mismatch'}
$env:STOCK_VARIANT='native-mic'
$env:STOCK_EXPECTED_SHA256=$sdk.dllSha256
$env:STOCK_EXIT='true'
$env:STOCK_RECEIVER_VOLUME='0'
$env:STOCK_SELECT_PLAYOUT='0'
$env:STOCK_AUDIO_PROCESSING_OFF='0'
& "$root/tools/windows/endpoint_volume.ps1"|Set-Content -Encoding UTF8 "$root/build/abi-volume-before.txt"
$started=Get-Date
$p=Start-Process -FilePath "$target/stock_capture_app.exe" -WorkingDirectory $target -PassThru
$p.WaitForExit()
$resultFile=Join-Path $env:TEMP 'stock_capture_result.json'
if((Get-Item $resultFile).LastWriteTime -lt $started){throw 'No fresh ABI result'}
$r=Get-Content $resultFile|ConvertFrom-Json
& "$root/tools/windows/endpoint_volume.ps1"|Set-Content -Encoding UTF8 "$root/build/abi-volume-after.txt"
$summary=[ordered]@{
 kind='old official05-header Flutter binaries with submitted candidate SDK DLL'
 dllSha256=$sdk.dllSha256
 oldAppSha256=(Get-FileHash "$target/stock_capture_app.exe").Hash.ToLower()
 oldPluginSha256=(Get-FileHash "$target/flutter_webrtc_plugin.dll").Hash.ToLower()
 exitCode=$p.ExitCode
 errors=@($r.errors)
 loadedDllMatches=($r.sdkIdentity.sha256 -eq $sdk.dllSha256)
 endpointVolumeMuteUnchanged=((Get-FileHash "$root/build/abi-volume-before.txt").Hash -eq (Get-FileHash "$root/build/abi-volume-after.txt").Hash)
 scope='no-argument factory and exercised old public interfaces; not official SDK or exhaustive ABI certification'
}
$summary|ConvertTo-Json -Depth 4|Set-Content -Encoding UTF8 "$root/build/abi-summary.json"
