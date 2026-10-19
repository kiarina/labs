param(
 [Parameter(Mandatory=$true)][string]$PrivateVendorDirectory,
 [Parameter(Mandatory=$true)][string]$OfficialArchive,
 [Parameter(Mandatory=$true)][ValidateSet('03','05')][string]$Version
)
$ErrorActionPreference='Stop'
$root=Join-Path $PrivateVendorDirectory 'third_party'
$target=Join-Path $root 'libwebrtc'
if(Test-Path $target){throw 'Use a fresh private vendor copy without an extracted SDK; never pass a shared cache'}
$manifest=Get-Content "$PSScriptRoot/../../results/official-sdks.json"|ConvertFrom-Json
$sdk=$manifest.sdks|Where-Object{$_.tag -eq "libwebrtc.m150.7871.$Version"}
if((Get-FileHash $OfficialArchive).Hash.ToLower() -ne $sdk.zipSha256){throw 'Official ZIP hash mismatch'}
$temp=Join-Path $root ('sdk-unpack-'+[Guid]::NewGuid().ToString('N'))
Expand-Archive -Path $OfficialArchive -DestinationPath $temp
$unpacked=Get-ChildItem $temp -Directory|Where-Object{Test-Path (Join-Path $_.FullName 'lib/libwebrtc.dll')}
if(@($unpacked).Count -ne 1){throw 'Unexpected official archive layout'}
Move-Item $unpacked.FullName $target
Remove-Item $temp
$download=Join-Path $root 'downloads'
New-Item -Type Directory -Force $download|Out-Null
Copy-Item $OfficialArchive (Join-Path $download 'libwebrtc-win-x64-release.zip')
$ini=Join-Path $root 'libwebrtc_version.ini'
(Get-Content $ini -Raw) -replace 'libwebrtc\.m150\.7871\.(03|05)',"libwebrtc.m150.7871.$Version"|Set-Content -Encoding ASCII $ini
$actual=(Get-FileHash (Join-Path $target 'lib/libwebrtc.dll')).Hash.ToLower()
if($actual -ne $sdk.dllSha256){throw 'Extracted official DLL hash mismatch'}
@{version=$Version;dllSha256=$actual;headers='same official archive';importLibrarySha256=(Get-FileHash (Join-Path $target 'lib/libwebrtc.dll.lib')).Hash.ToLower()}|ConvertTo-Json
